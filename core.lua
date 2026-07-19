  -- ====================================================================================
  -- PET SIMULATOR X | ANTI-CRASH & OPTIMIZED FARM HUB (DUAL MODE + HOTKEY 'F')
  -- ====================================================================================
  
  local env = getgenv()

  -- Native/executor crashes cannot be caught by pcall. The production loader keeps
  -- tracing enabled and deliberately yields between heavy startup stages.
  local bootTraceEnabled = env.PSX_OG_TRACE_BOOT == true
  local safeBootEnabled = env.PSX_OG_SAFE_BOOT == true
  local safeBootDelay = math.clamp(tonumber(env.PSX_OG_SAFE_BOOT_DELAY) or 0.03, 0, 0.25)
  local bootTraceLines = {}
  local function bootTrace(stage)
      if bootTraceEnabled then
          local sourceLine = nil
          pcall(function()
              if debug and type(debug.info) == "function" then
                  sourceLine = debug.info(2, "l")
              end
          end)
          local line = string.format(
              "[%0.3f] %s%s",
              os.clock(),
              tostring(stage),
              sourceLine and (" | line=" .. tostring(sourceLine)) or ""
          )
          table.insert(bootTraceLines, line)
          pcall(function()
              if type(writefile) == "function" then
                  writefile("PSX_OG_boot_trace.txt", table.concat(bootTraceLines, "\n"))
              end
          end)
          print("[PSX BOOT] " .. tostring(stage))
      end

      if safeBootEnabled then
          task.wait(safeBootDelay)
      end
  end

  bootTrace("01 main chunk entered")

  -- Отключаем состояние экспериментального reward-hook из предыдущего запуска.
  if type(env.PSX_OG_RewardInvokeCaptureState) == "table" then
      env.PSX_OG_RewardInvokeCaptureState.active = false
      env.PSX_OG_RewardInvokeCaptureState.remote = nil
  end
  if type(env.PSX_OG_BoostRemoteCaptureState) == "table" then
      env.PSX_OG_BoostRemoteCaptureState.active = false
      env.PSX_OG_BoostRemoteCaptureState.remote = nil
  end

  local function disconnectRunConnections()
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
  end

  disconnectRunConnections()
  bootTrace("02 previous run disconnected")

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
      FarmMode = "Teleport + Radius (Small Coins)",
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
      FarmLocation = "Current World",
      FarmZone = "Player Zone"
  }
  
  -- NATIVE UI INITIALIZATION
  if type(env.PSX_OG_UI_CLEANUP) == "function" then
      pcall(env.PSX_OG_UI_CLEANUP)
  end

  bootTrace("03 native UI selected")
  if type(createNativeUI) ~= "function" then
      error("Native UI factory is missing; use the standalone build", 0)
  end
  local uiInitialized, WindUI = pcall(createNativeUI)
  if not uiInitialized then
      error("Native UI initialization failed: " .. tostring(WindUI), 0)
  end
  bootTrace("04 native UI initialized")

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
      Author = "Native English UI",
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
  bootTrace("07 main window created")

  local function destroyUI()
      local destroyed = false
      if Window and type(Window.Destroy) == "function" then
          destroyed = pcall(function() Window:Destroy() end)
      end
      if not destroyed and WindUI and type(WindUI.Destroy) == "function" then
          pcall(function() WindUI:Destroy() end)
      end
  end

  env.PSX_OG_UI_CLEANUP = destroyUI
  
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
  local clickRadius = 45 -- Click spread radius.
  local lastChestTarget = nil -- Click a chest target only once per lock.
  
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

  local getServerCurrentWorldName
  local getServerZoneNames
  local cachedCurrentWorld = nil
  local nextCurrentWorldRefresh = 0

  local function getCurrentWorldName()
      local now = os.clock()
      if now < nextCurrentWorldRefresh and cachedCurrentWorld then
          return cachedCurrentWorld
      end
      nextCurrentWorldRefresh = now + 0.25

      if type(getServerCurrentWorldName) == "function" then
          local serverWorld = getServerCurrentWorldName()
          if serverWorld then
              cachedCurrentWorld = serverWorld
              return cachedCurrentWorld
          end
      end

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

      cachedCurrentWorld = bestWorld or "Unknown World"
      return cachedCurrentWorld
  end

  local function getWorldZoneOptions(worldChoice)
      local options = {}
      local seen = {}
      local resolvedWorld = worldChoice
      if worldChoice == "Current World" then
          table.insert(options, "Player Zone")
          seen["Player Zone"] = true
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
      elseif worldChoice == "Current World" then
          for _, zoneName in ipairs(getLiveMapAreaNames()) do
              if not seen[zoneName] then
                  seen[zoneName] = true
                  table.insert(options, zoneName)
              end
          end
      end

      if type(getServerZoneNames) == "function" then
          for _, zoneName in ipairs(getServerZoneNames(resolvedWorld)) do
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
  local getServerDedicatedChestZoneAtPosition

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
          (type(getServerDedicatedChestZoneAtPosition) == "function"
              and getServerDedicatedChestZoneAtPosition(root.Position))
          or getDedicatedChestZoneAtPosition(root.Position)
          or getAreaForPosition(root.Position)
      ) or nil
      return cachedPlayerArea
  end

  local function getSelectedFarmZone()
      if _G.FarmZone == "Player Zone" then
          return getPlayerAreaName()
      end
      return TeleportAreaAliases[_G.FarmZone] or _G.FarmZone
  end

  local function getSelectedFarmWorld()
      if _G.FarmLocation == "Current World" then
          return getCurrentWorldName()
      end
      return _G.FarmLocation
  end

  local function getFarmContextKey()
      return tostring(game.PlaceId)
          .. "|" .. tostring(getSelectedFarmWorld() or "Unknown World")
          .. "|" .. tostring(getSelectedFarmZone() or "Unknown Zone")
  end
  
  -- Пространственная привязка монет к областям живёт только пока существуют модели.
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
  
  -- Поиск монеты (исходная логика)
  local function coinIsInLocation(coinModel)
      local selectedWorld = getSelectedFarmWorld()
      local loadedWorld = getCurrentWorldName()
      if _G.FarmLocation ~= "Current World"
          and loadedWorld ~= "Unknown World"
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
  local boostDirectRemoteSource = "not used yet"
  local boostStatusParagraph = nil
  local eggDropdown = nil
  local eggCatalogParagraph = nil
  local eggStatusParagraph = nil
  local eggStatusText = "Waiting to start"
  local eggDisplayToId = {}
  local eggIdToDisplay = {}
  local loadedEggsById = {}
  local lastEggCatalogSignature = nil
  local fastEggGateArmed = false
  local eggAnimationGateActive = false
  local uiLastDescription = {}
  local uiNextDescriptionUpdate = {}

  local function setDescriptionCached(control, text, minimumInterval)
      if not control then return false end

      text = tostring(text or "")
      if uiLastDescription[control] == text then return true end

      local now = os.clock()
      if now < (uiNextDescriptionUpdate[control] or 0) then return false end

      local success = pcall(function()
          control:SetDesc(text)
      end)
      if success then
          uiLastDescription[control] = text
          uiNextDescriptionUpdate[control] = now + math.max(0, tonumber(minimumInterval) or 0)
      end
      return success
  end

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

  local function sendBoostThroughNetwork(library, boostName)
      local network = library and library.Network
      if not network or type(network.Fire) ~= "function" then
          return false, "Library.Network.Fire is unavailable"
      end

      local success, err = pcall(network.Fire, "Activate Boost", boostName)
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
          boostDirectRemoteSource = "resolver error: " .. tostring(remote)
          return false, boostDirectRemoteSource
      end
      if not remote then
          boostDirectRemoteSource = "RemoteEvent was not found"
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
          return {"Loading egg catalog..."}, nil, 0, 0
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
          options = {"No eggs found"}
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
              and string.format(" | selected distance %.1f", targetInfo.distance)
              or " | selected egg is not loaded"
          setDescriptionCached(
              eggCatalogParagraph,
              string.format("● current world: %d | catalog total: %d%s", loadedCount, totalCount, distanceText),
              1
          )
      end

      return options, selectedLabel
  end

  local function setEggAnimationGate(enabled)
      enabled = enabled == true
      if not enabled and not eggAnimationGateActive then return end

      local library = getPSXLibrary()
      if library and library.Variables then
          local success = pcall(function() library.Variables.OpeningEgg = enabled end)
          if success then eggAnimationGateActive = enabled end
      end
  end

  local function openEgg(eggName, triple)
      eggName = tostring(eggName or ""):match("^%s*(.-)%s*$")
      if eggName == "" then
          return false, "Select an exact egg name"
      end

      local library = getPSXLibrary()
      local network = library and library.Network
      if not network then
          return false, "Library.Network is not loaded yet"
      end
      if library.Loaded ~= true then
          return false, "Library is still loading"
      end

      if triple then
          local saveData = getSaveData()
          if not saveData then
              return false, "Player save is not loaded yet"
          end
          if not hasGamepass(saveData, "Triple Egg Open") then
              return false, "x3 requires the Triple Egg Open gamepass"
          end
      end

      local eggDirectory = library.Directory and library.Directory.Eggs
      if type(eggDirectory) ~= "table" or not eggDirectory[eggName] then
          return false, "Egg ID is missing from Library.Directory.Eggs: " .. eggName
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
          return false, "Buy Egg RemoteFunction was not found in the Network registry"
      end

      local callOk, purchased, message = pcall(function()
          return buyEggRemote:InvokeServer(eggName, triple == true)
      end)
      if not callOk then
          return false, string.format(
              "Buy Egg remote [%s] (%s) failed: %s",
              tostring(remoteIndex or "?"),
              tostring(remoteSource),
              tostring(purchased)
          )
      end
      if purchased then
          return true, string.format(
              "%s | remote [%s], %s",
              triple and "Opened x3" or "Opened x1",
              tostring(remoteIndex or "?"),
              tostring(remoteSource)
          )
      end

      local failureText = tostring(message or "Server rejected the egg purchase")
      if eggDistance and eggDistance > 25 then
          failureText = failureText .. string.format(" | distance %.1f (normal limit: 25)", eggDistance)
      elseif not loadedInfo then
          failureText = failureText .. " | egg instance was not found in the current Workspace"
      end
      return false, failureText
  end
  
  bootTrace("08 core helpers declared")
  task.wait()
  -- ВКЛАДКИ WINDUI
  local OverviewTab = Window:Tab({ Title = "Overview", Icon = "layout-dashboard" })
  local ClickFarmTab = Window:Tab({ Title = "Click Farm", Icon = "mouse-pointer-click" })
  local PetsTab = Window:Tab({ Title = "Pets", Icon = "paw-print" })
  local LootTab = Window:Tab({ Title = "Loot", Icon = "package-open" })
  local BoostsTab = Window:Tab({ Title = "Boosts", Icon = "zap" })
  local EggTab = Window:Tab({ Title = "Eggs", Icon = "egg" })
  local SettingsTab = Window:Tab({ Title = "Settings", Icon = "settings" })
  bootTrace("09 tabs created")
  task.wait()

  local OverviewSection = OverviewTab:Section({ Title = "Status", Box = true, Opened = true })
  OverviewSection:Paragraph({
      Title = "Controls",
      Desc = "RightShift — show or hide the menu\nF — toggle click farming"
  })

  local currencyTrackerParagraph = OverviewSection:Paragraph({
      Title = "Farm Rate",
      Desc = "Coins/min: enable click farm or pet farm"
  })
  currencyTrackerLabel = {
      Set = function(_, text)
          setDescriptionCached(currencyTrackerParagraph, text, 0.5)
      end
  }

  OverviewSection:Dropdown({
      Title = "Tracked Currency",
      Values = {"Coins", "Diamonds", "Fantasy Coins", "Tech Coins", "Rainbow Coins", "Cartoon Coins"},
      Value = "Coins",
      Multi = false,
      AllowNone = false,
      Callback = function(value)
          _G.TrackedCurrency = value
          table.clear(currencySamples)
          currencyTrackerLabel:Set(value .. "/min: waiting for data...")
      end
  })

  local ClickFarmSection = ClickFarmTab:Section({ Title = "Standard Farm", Box = true, Opened = true })
  local AutoFarmToggle = ClickFarmSection:Toggle({
      Title = "Auto Aim and Click",
      Desc = "Quick toggle — F key",
      Value = false,
      Callback = function(value) _G.AutoFarm = value end
  })

  ClickFarmSection:Dropdown({
      Title = "Farm Mode",
      Values = {"Range Click (Big Chest)", "Teleport + Radius (Small Coins)"},
      Value = "Teleport + Radius (Small Coins)",
      Multi = false,
      AllowNone = false,
      Callback = function(value) _G.FarmMode = value end
  })

  ClickFarmSection:Slider({
      Title = "Click Delay",
      Desc = "Lower values send clicks more frequently",
      Step = 5,
      Value = { Min = 5, Max = 100, Default = 10 },
      Callback = function(value) _G.FarmDelay = value / 100 end
  })

  bootTrace("10 overview and click-farm menu created")
  task.wait()
  local PetBaseSection = PetsTab:Section({ Title = "Pet Auto Farm", Box = true, Opened = true })
  PetBaseSection:Toggle({
      Title = "Farm Coins with Pets",
      Desc = "Pets stay locked to targets in the selected zone",
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
      "All Pets on Boss Chest",
      "All Pets on One Large Target",
      "Different Strongest Targets",
      "Different Weakest Targets"
  }
  local petModesByLabel = {
      ["All Pets on Boss Chest"] = "AllOneBossChest",
      ["All Pets on One Large Target"] = "AllOneBigCoin",
      ["Different Strongest Targets"] = "DifferentStrongest",
      ["Different Weakest Targets"] = "DifferentWeakest"
  }
  local petModeSettingsSection = nil
  local lastPetModeSettingsLabel = nil

  local function rebuildPetModeSettings(modeLabel)
      if petModeSettingsSection and lastPetModeSettingsLabel == modeLabel then
          return
      end

      if petModeSettingsSection then
          local destroyed = pcall(function() petModeSettingsSection:Destroy() end)
          if not destroyed then return end
          petModeSettingsSection = nil
      end

      petModeSettingsSection = PetsTab:Section({
          Title = "Strategy Settings",
          Box = true,
          Opened = true
      })
      lastPetModeSettingsLabel = modeLabel

      local mode = petModesByLabel[modeLabel] or "DifferentStrongest"
      if mode == "AllOneBossChest" then
          petModeSettingsSection:Paragraph({
              Title = "Boss Chest",
              Desc = "Only permanent catalog chests: Magma, Grand Heaven, Giant Tech, Ancient, Alien and others. Regular chests are ignored."
          })
      elseif mode == "AllOneBigCoin" then
          petModeSettingsSection:Paragraph({
              Title = "Large Regular Targets",
              Desc = "All pets attack one highest-HP target. Regular chests are allowed; boss chests are excluded."
          })
          petModeSettingsSection:Slider({
              Title = "Minimum Target Strength",
              Desc = "Percentage of the highest-HP target found in the selected zone",
              Step = 5,
              Value = { Min = 10, Max = 100, Default = _G.BigCoinThreshold },
              Callback = function(value) _G.BigCoinThreshold = value end
          })
      elseif mode == "DifferentWeakest" then
          petModeSettingsSection:Paragraph({
              Title = "Separate Weak Target Farm",
              Desc = "Each pet receives a separate weak target. Extra pets share the best available targets. Boss chests are excluded."
          })
      else
          petModeSettingsSection:Paragraph({
              Title = "Separate Strong Target Farm",
              Desc = "Targets are sorted by server HP and assigned by strength. Extra pets remain active. Boss chests are excluded."
          })
      end
  end

  PetBaseSection:Dropdown({
      Title = "Assignment Strategy",
      Values = petModeLabels,
      Value = "Different Strongest Targets",
      Multi = false,
      AllowNone = false,
      Callback = function(value)
          _G.PetFarmMode = petModesByLabel[value] or "DifferentStrongest"
          rebuildPetModeSettings(value)
      end
  })

  local worldDropdownValues = { "Current World" }
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
          selectedZone = _G.FarmLocation == "Current World"
              and "Player Zone"
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
      Title = "World",
      Desc = "Current World updates dynamically; a selected world shows only its own zones",
      Values = worldDropdownValues,
      Value = "Current World",
      Multi = false,
      AllowNone = false,
      Callback = function(value)
          _G.FarmLocation = value
          refreshZoneDropdown(true)
      end
  })

  local initialZoneOptions = getWorldZoneOptions("Current World")
  zoneDropdown = PetBaseSection:Dropdown({
      Title = "Zone",
      Values = initialZoneOptions,
      Value = "Player Zone",
      Multi = false,
      AllowNone = false,
      Callback = function(value) _G.FarmZone = value end
  })

  lastZoneOptionsSignature = tostring(_G.FarmLocation) .. "|" .. table.concat(initialZoneOptions, "\0")

  local currentZoneParagraph = PetBaseSection:Paragraph({
      Title = "Active Filter",
      Desc = "Detecting the player's world and position..."
  })

  if not petModeSettingsSection then
      rebuildPetModeSettings("Different Strongest Targets")
  end
  bootTrace("11 pet menu created")
  task.wait()

  local LootSection = LootTab:Section({ Title = "Auto Collect", Box = true, Opened = true })
  LootSection:Toggle({
      Title = "Orb Magnet",
      Desc = "Automatically collect orbs",
      Value = false,
      Callback = function(value) _G.AutoOrbs = value end
  })
  LootSection:Toggle({
      Title = "Lootbag Magnet",
      Desc = "Automatically collect lootbags",
      Value = false,
      Callback = function(value) _G.AutoLootbags = value end
  })

  local BoostsSection = BoostsTab:Section({ Title = "Auto Renew", Box = true, Opened = true })
  BoostsSection:Toggle({
      Title = "Automatically Use Boosts",
      Desc = "Uses enabled boosts shortly before their timers expire",
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
      Title = "Renew Early",
      Desc = "Seconds before expiration to use the next boost",
      Step = 1,
      Value = { Min = 1, Max = 30, Default = 5 },
      Callback = function(value) _G.BoostRenewBefore = value end
  })

  for _, definition in ipairs(boostDefinitions) do
      local currentDefinition = definition
      BoostsSection:Toggle({
          Title = currentDefinition.title,
          Desc = "Remaining time and inventory are read from the player save",
          Value = true,
          Callback = function(value)
              _G.EnabledBoosts[currentDefinition.key] = value
          end
      })
  end

  boostStatusParagraph = BoostsSection:Paragraph({
      Title = "Boost Status",
      Desc = "Waiting for Library.Save data..."
  })

  bootTrace("12 loot and boost menus created")
  task.wait()
  local EggSection = EggTab:Section({ Title = "Auto Open", Box = true, Opened = true })
  local initialEggOptions = {"Press Refresh Egg List"}
  local initialEggLabel = initialEggOptions[1]
  eggDropdown = EggSection:Dropdown({
      Title = "Egg",
      Desc = "● loaded in the current world, ○ catalog only; the server requires you to stand nearby",
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
      Title = "Refresh Egg List",
      Desc = "Reads Library.Directory.Eggs and the current Workspace again",
      Icon = "refresh-cw",
      Callback = function() refreshEggDropdown(true) end
  })
  eggCatalogParagraph = EggSection:Paragraph({
      Title = "Catalog",
      Desc = "The list loads when refreshed or when auto open is enabled"
  })
  EggSection:Dropdown({
      Title = "Eggs per Open",
      Desc = "x3 requires the Triple Egg Open gamepass",
      Values = {"Single (x1)", "Triple (x3)"},
      Value = "Single (x1)",
      Multi = false,
      AllowNone = false,
      Callback = function(value)
          _G.EggOpenMode = value == "Triple (x3)" and "Triple" or "Single"
      end
  })
  EggSection:Slider({
      Title = "Open Interval",
      Desc = "Milliseconds; a safe minimum is used when animation skip is disabled",
      Step = 10,
      Value = { Min = 60, Max = 1000, Default = 120 },
      Callback = function(value) _G.EggDelay = value / 1000 end
  })
  local SkipAnimToggle = EggSection:Toggle({
      Title = "Skip Animation",
      Desc = "Handles Open Egg before pet models and the animation UI are created",
      Value = true,
      Callback = function(value)
          _G.SkipAnim = value == true
          fastEggGateArmed = false
          setEggAnimationGate(false)
      end
  })
  local AutoEggToggle = EggSection:Toggle({
      Title = "Auto Open Eggs",
      Value = false,
      Callback = function(value)
          _G.AutoEgg = value == true
          fastEggGateArmed = false
          setEggAnimationGate(false)
          if _G.AutoEgg then refreshEggDropdown(true) end
      end
  })
  eggStatusParagraph = EggSection:Paragraph({
      Title = "Status",
      Desc = eggStatusText
  })
  bootTrace("13 egg menu created without catalog scan")
  task.wait()
  local AppearanceSection = SettingsTab:Section({ Title = "Interface", Box = true, Opened = true })
  AppearanceSection:Slider({
      Title = "Window Transparency",
      Desc = "0 is opaque; 90 is almost transparent",
      Step = 5,
      Value = { Min = 0, Max = 90, Default = 20 },
      Callback = function(value)
          pcall(function() Window:SetBackgroundTransparency(value / 100) end)
          pcall(function() Window:SetBackgroundImageTransparency(math.min(1, value / 100 + 0.1)) end)
      end
  })

  local ScriptSection = SettingsTab:Section({ Title = "Script", Box = true, Opened = true })
  ScriptSection:Button({
      Title = "STOP AND REMOVE SCRIPT",
      Desc = "Stop all loops and close the interface",
      Icon = "power",
      Callback = function()
          env.PSX_OG_Running = false
          if env.PSX_OG_RunToken == runToken then
              env.PSX_OG_RunToken = nil
          end
          if env.PSX_OG_UI_CLEANUP == destroyUI then
              env.PSX_OG_UI_CLEANUP = nil
          end
          disconnectRunConnections()
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
          destroyUI()
      end
  })
  bootTrace("14 complete menu tree created")
  task.wait()
  
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
  local clickFarmWasActive = false
  trackRunConnection(RunService.RenderStepped:Connect(function()
      -- Разморозка и возврат камеры при выключении
      if not _G.AutoFarm or _G.AutoPetCoins or not isScriptRunning() then
          if not clickFarmWasActive then return end
          clickFarmWasActive = false
          local char = localPlayer.Character
          local root = char and char:FindFirstChild("HumanoidRootPart")
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

      clickFarmWasActive = true
      local char = localPlayer.Character
      local root = char and char:FindFirstChild("HumanoidRootPart")

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
      
      if _G.FarmMode == "Teleport + Radius (Small Coins)" then
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
      
      if _G.FarmMode == "Range Click (Big Chest)" then
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
  bootTrace("15 click-farm connection registered")
  
  -- ====================================================================================
  -- 1.5. АВТОФАРМ ПИТОМЦАМИ ЧЕРЕЗ REMOTE-КАРТУ
  -- ====================================================================================
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

  local getCoinHealth
  local getCoinPriorityHealth
  local readCoinBool
  local coinCanBeFarmed
  local getCoinName
  local normalizeCoinName
  local BossChestNames

  -- Серверный каталог монет является главным источником состояния. Модели в
  -- Workspace используются только для локальной анимации движения питомца.
  local serverCoinRecords = {}
  local serverCoinSnapshotReady = false
  local serverCoinNetworkReady = false
  local serverCoinFetchInFlight = false
  local serverCoinFetchRequested = true
  local serverCoinNextFetchAt = 0
  local serverCoinEventRevision = 0
  local serverCoinRemovalRevisions = {}
  local serverChestAnchors = {}
  local allocatorWakeRevision = 0

  local function wakePetAllocator()
      allocatorWakeRevision = allocatorWakeRevision + 1
  end

  local function refreshCoinsFolderReference()
      local currentThings = workspace:FindFirstChild("__THINGS")
      coinsFolder = currentThings and currentThings:FindFirstChild("Coins")
      return coinsFolder
  end

  local function resolveDisplayWorldName(rawWorld)
      if rawWorld == nil then return nil end
      for _, worldName in ipairs(WorldOrder) do
          if areaNamesMatch(rawWorld, worldName) then
              return worldName
          end
      end
      return tostring(rawWorld)
  end

  local function worldNamesMatch(rawWorld, displayWorld)
      if rawWorld == nil or rawWorld == "" or displayWorld == nil then return true end
      return areaNamesMatch(rawWorld, displayWorld)
          or resolveDisplayWorldName(rawWorld) == displayWorld
  end

  local function getServerCoinDedicatedZone(record)
      if type(record) ~= "table" then return nil end
      return DedicatedChestZoneByCoinName[normalizeAreaName(record.Name)]
  end

  local function normalizeNetworkPetSet(rawPets)
      local result = {}
      if type(rawPets) ~= "table" then return result end

      for key, value in pairs(rawPets) do
          local petId = nil
          if type(key) == "number" then
              if type(value) == "table" then
                  petId = rawget(value, "uid") or rawget(value, "id")
              else
                  petId = value
              end
          elseif value == true then
              petId = key
          elseif type(value) == "table" then
              petId = rawget(value, "uid") or rawget(value, "id") or key
          elseif type(value) == "string" then
              petId = value
          elseif value ~= false and value ~= nil then
              petId = key
          end

          if petId ~= nil then
              result[tostring(petId)] = true
          end
      end
      return result
  end

  local function updateServerChestAnchor(record)
      local zoneName = getServerCoinDedicatedZone(record)
      if not zoneName or typeof(record.Position) ~= "Vector3" then return end
      local worldName = resolveDisplayWorldName(record.World) or tostring(record.World or "")
      serverChestAnchors[worldName .. "|" .. zoneName] = record.Position
  end

  local function applyServerCoinData(rawCoinId, data, fromEvent)
      if rawCoinId == nil or type(data) ~= "table" then return nil end
      local coinId = tostring(rawCoinId)
      local record = serverCoinRecords[coinId]
      if not record then
          record = {
              IsServerCoinRecord = true,
              Id = coinId,
              PetSet = {}
          }
          serverCoinRecords[coinId] = record
      end

      local area = rawget(data, "a") or rawget(data, "Area") or rawget(data, "area")
      local world = rawget(data, "w") or rawget(data, "World") or rawget(data, "world")
      local name = rawget(data, "n") or rawget(data, "Name") or rawget(data, "name")
      local position = rawget(data, "p") or rawget(data, "Position") or rawget(data, "position")
      local health = tonumber(rawget(data, "h") or rawget(data, "Health") or rawget(data, "health"))
      local maxHealth = tonumber(rawget(data, "mh") or rawget(data, "MaxHealth") or rawget(data, "maxHealth"))

      if area ~= nil then record.Area = tostring(area) end
      if world ~= nil then record.World = tostring(world) end
      if name ~= nil then record.Name = tostring(name) end
      if typeof(position) == "Vector3" then record.Position = position end
      if health ~= nil then record.Health = health end
      if maxHealth ~= nil then record.MaxHealth = maxHealth end
      record.Health = tonumber(record.Health) or 0
      record.MaxHealth = math.max(tonumber(record.MaxHealth) or record.Health, record.Health)
      record.Removed = false

      local rawPets = rawget(data, "pets") or rawget(data, "Pets")
      if rawPets ~= nil then
          record.PetSet = normalizeNetworkPetSet(rawPets)
      end

      if fromEvent then
          serverCoinEventRevision = serverCoinEventRevision + 1
          record.EventRevision = serverCoinEventRevision
          serverCoinRemovalRevisions[coinId] = nil
      end
      updateServerChestAnchor(record)
      return record
  end

  local function removeServerCoin(rawCoinId, fromEvent)
      local coinId = tostring(rawCoinId)
      local record = serverCoinRecords[coinId]
      if fromEvent then
          serverCoinEventRevision = serverCoinEventRevision + 1
          serverCoinRemovalRevisions[coinId] = serverCoinEventRevision
      end
      if record then
          record.Health = 0
          record.Removed = true
          record.PetSet = {}
          if fromEvent then
              record.EventRevision = serverCoinEventRevision
          end
          serverCoinRecords[coinId] = nil
      end
      wakePetAllocator()
  end

  local function requestServerCoinRefresh(immediate)
      serverCoinFetchRequested = true
      if immediate then serverCoinNextFetchAt = 0 end
      wakePetAllocator()
  end

  local function connectNamedSignal(signalFactory, signalName, handler)
      local signal
      local success = pcall(function() signal = signalFactory(signalName) end)
      if not success or not signal or type(signal.Connect) ~= "function" then
          return false
      end

      local connected, connection = pcall(function()
          return signal:Connect(function(...)
              local handled, message = pcall(handler, ...)
              if not handled then
                  warn("[PSX farm] " .. tostring(signalName) .. ": " .. tostring(message))
              end
          end)
      end)
      if connected and connection then
          trackRunConnection(connection)
          return true
      end
      return false
  end

  local function ensureServerCoinNetwork()
      if serverCoinNetworkReady then return true end
      local library = getPSXLibrary()
      local network = library and library.Network
      if not network or type(network.Invoke) ~= "function" or type(network.Fired) ~= "function" then
          return false
      end
      if library.Loaded ~= nil and library.Loaded ~= true then return false end

      local fired = function(name) return network.Fired(name) end
      connectNamedSignal(fired, "New Coin", function(coinId, data)
          applyServerCoinData(coinId, data, true)
          wakePetAllocator()
      end)
      connectNamedSignal(fired, "Update Coin Pets", function(coinId, pets)
          local record = serverCoinRecords[tostring(coinId)]
          if record then
              record.PetSet = normalizeNetworkPetSet(pets)
              serverCoinEventRevision = serverCoinEventRevision + 1
              record.EventRevision = serverCoinEventRevision
          else
              requestServerCoinRefresh(true)
          end
          wakePetAllocator()
      end)
      connectNamedSignal(fired, "Update Coin Health", function(coinId, health)
          local record = serverCoinRecords[tostring(coinId)]
          if record then
              record.Health = tonumber(health) or record.Health or 0
              serverCoinEventRevision = serverCoinEventRevision + 1
              record.EventRevision = serverCoinEventRevision
              if record.Health <= 0 then record.Removed = true end
          else
              requestServerCoinRefresh(true)
          end
          wakePetAllocator()
      end)
      connectNamedSignal(fired, "Remove Coin", function(coinId)
          removeServerCoin(coinId, true)
      end)

      local librarySignal = library.Signal
      if librarySignal and type(librarySignal.Fired) == "function" then
          connectNamedSignal(function(name) return librarySignal.Fired(name) end, "World Changed", function()
              for _, record in pairs(serverCoinRecords) do
                  record.Health = 0
                  record.Removed = true
              end
              table.clear(serverCoinRecords)
              table.clear(serverCoinRemovalRevisions)
              table.clear(serverChestAnchors)
              serverCoinSnapshotReady = false
              cachedCurrentWorld = nil
              nextCurrentWorldRefresh = 0
              requestServerCoinRefresh(true)
          end)
      end

      serverCoinNetworkReady = true
      requestServerCoinRefresh(true)
      return true
  end

  local function refreshServerCoinSnapshot()
      if serverCoinFetchInFlight or not ensureServerCoinNetwork() then return false end
      local library = getPSXLibrary()
      local network = library and library.Network
      if not network or type(network.Invoke) ~= "function" then return false end

      serverCoinFetchInFlight = true
      serverCoinFetchRequested = false
      local eventRevisionAtStart = serverCoinEventRevision
      local success, response = pcall(network.Invoke, "Get Coins")
      local now = os.clock()

      local processed = success and type(response) == "table"
      if processed then
          local processSuccess, processError = pcall(function()
              local seen = {}
              for coinId, data in pairs(response) do
                  if type(data) == "table" then
                      coinId = tostring(coinId)
                      local removalRevision = tonumber(serverCoinRemovalRevisions[coinId]) or 0
                      local existing = serverCoinRecords[coinId]
                      local existingRevision = existing and (tonumber(existing.EventRevision) or 0) or 0
                      if removalRevision <= eventRevisionAtStart then
                          seen[coinId] = true
                          serverCoinRemovalRevisions[coinId] = nil
                          if existingRevision <= eventRevisionAtStart then
                              applyServerCoinData(coinId, data, false)
                          end
                      end
                  end
              end

              local staleIds = {}
              for coinId, record in pairs(serverCoinRecords) do
                  if not seen[coinId] and (tonumber(record.EventRevision) or 0) <= eventRevisionAtStart then
                      table.insert(staleIds, coinId)
                  end
              end
              for _, coinId in ipairs(staleIds) do removeServerCoin(coinId, false) end
          end)
          processed = processSuccess
          if not processSuccess then
              warn("[PSX farm] Get Coins apply failed: " .. tostring(processError))
          end
      end

      if processed then
          serverCoinSnapshotReady = true
          serverCoinNextFetchAt = now + 4
          cachedCurrentWorld = nil
          nextCurrentWorldRefresh = 0
          wakePetAllocator()
      else
          serverCoinFetchRequested = true
          serverCoinNextFetchAt = now + 0.5
      end

      serverCoinFetchInFlight = false
      return processed
  end

  getServerCurrentWorldName = function()
      local library = getPSXLibrary()
      local worldCmds = library and library.WorldCmds
      if worldCmds and type(worldCmds.Get) == "function" then
          local success, rawWorld = pcall(worldCmds.Get)
          if success and rawWorld then return resolveDisplayWorldName(rawWorld) end
      end

      local worldCounts = {}
      local bestWorld, bestCount = nil, 0
      for _, record in pairs(serverCoinRecords) do
          local displayName = resolveDisplayWorldName(record.World)
          if displayName then
              worldCounts[displayName] = (worldCounts[displayName] or 0) + 1
              if worldCounts[displayName] > bestCount then
                  bestWorld, bestCount = displayName, worldCounts[displayName]
              end
          end
      end
      if bestWorld then return bestWorld end
      return nil
  end

  getServerZoneNames = function(displayWorld)
      local names, seen = {}, {}
      for _, record in pairs(serverCoinRecords) do
          if worldNamesMatch(record.World, displayWorld) then
              local dedicatedZone = getServerCoinDedicatedZone(record)
              local zoneName = dedicatedZone or record.Area
              if zoneName and zoneName ~= "" and not seen[zoneName] then
                  seen[zoneName] = true
                  table.insert(names, zoneName)
              end
          end
      end
      for key in pairs(serverChestAnchors) do
          local worldName, zoneName = string.match(key, "^(.-)|(.+)$")
          if worldNamesMatch(worldName, displayWorld) and not seen[zoneName] then
              seen[zoneName] = true
              table.insert(names, zoneName)
          end
      end
      table.sort(names)
      return names
  end

  getServerDedicatedChestZoneAtPosition = function(position)
      if typeof(position) ~= "Vector3" then return nil end
      local currentWorld = getServerCurrentWorldName() or getCurrentWorldName()
      local bestZone, bestDistance = nil, math.huge
      for key, anchorPosition in pairs(serverChestAnchors) do
          local worldName, zoneName = string.match(key, "^(.-)|(.+)$")
          if worldNamesMatch(worldName, currentWorld) then
              local distance = (position - anchorPosition).Magnitude
              if distance < bestDistance then
                  bestZone, bestDistance = zoneName, distance
              end
          end
      end
      return bestDistance <= DEDICATED_CHEST_ZONE_RADIUS and bestZone or nil
  end

  local function isServerCoinRecord(target)
      return type(target) == "table" and target.IsServerCoinRecord == true and target.Id ~= nil
  end

  local function getFarmTargetId(target)
      if isServerCoinRecord(target) then return tostring(target.Id) end
      return getCoinNetworkId(target)
  end

  local function getFarmTargetModel(target)
      if not isServerCoinRecord(target) then return target end
      if target.Model and target.Model.Parent then return target.Model end

      local folder = refreshCoinsFolderReference()
      if not folder then return nil end
      local direct = folder:FindFirstChild(tostring(target.Id))
      if direct then
          target.Model = direct
          return direct
      end

      for _, model in ipairs(folder:GetChildren()) do
          if tostring(getCoinNetworkId(model)) == tostring(target.Id) then
              target.Model = model
              return model
          end
      end
      return nil
  end

  local function getFarmTargetPosition(target)
      if isServerCoinRecord(target) and typeof(target.Position) == "Vector3" then
          return target.Position
      end
      return getCoinPosition(getFarmTargetModel(target))
  end

  local function getFarmTargetCurrentHealth(target)
      if isServerCoinRecord(target) then return tonumber(target.Health) or 0 end
      return getCoinHealth and getCoinHealth(target) or 0
  end

  local function getFarmTargetMaxHealth(target)
      if isServerCoinRecord(target) then
          return math.max(tonumber(target.MaxHealth) or 0, tonumber(target.Health) or 0)
      end
      return getCoinPriorityHealth and getCoinPriorityHealth(target) or getFarmTargetCurrentHealth(target)
  end

  local function getFarmTargetName(target)
      if isServerCoinRecord(target) then return tostring(target.Name or target.Id or "") end
      return getCoinName and getCoinName(target) or tostring(target and target.Name or "")
  end

  local function getServerAnchorForZone(worldName, zoneName)
      for key, anchorPosition in pairs(serverChestAnchors) do
          local anchorWorld, anchorZone = string.match(key, "^(.-)|(.+)$")
          if worldNamesMatch(anchorWorld, worldName) and areaNamesMatch(anchorZone, zoneName) then
              return anchorPosition
          end
      end
      return nil
  end

  local function serverCoinIsInLocation(record)
      local selectedWorld = getSelectedFarmWorld()
      if record.World and selectedWorld and not worldNamesMatch(record.World, selectedWorld) then
          return false
      end

      local selectedZone = getSelectedFarmZone()
      if not selectedZone then return false end

      local dedicatedZone = getServerCoinDedicatedZone(record)
      if dedicatedZone then
          return areaNamesMatch(dedicatedZone, selectedZone)
      end
      if areaNamesMatch(record.Area, selectedZone) then return true end

      local anchor = getServerAnchorForZone(selectedWorld, selectedZone)
      return anchor ~= nil
          and typeof(record.Position) == "Vector3"
          and (record.Position - anchor).Magnitude <= DEDICATED_CHEST_ZONE_RADIUS
  end

  local function farmTargetCanBeUsed(target)
      if isServerCoinRecord(target) then
          if target.Removed or (tonumber(target.Health) or 0) <= 0 then return false end
          return serverCoinIsInLocation(target)
      end
      return coinCanBeFarmed and coinCanBeFarmed(target) and coinIsInLocation(target)
  end

  local function farmTargetIsAlive(target)
      if isServerCoinRecord(target) then
          return not target.Removed and (tonumber(target.Health) or 0) > 0
      end
      return target and target.Parent and getFarmTargetCurrentHealth(target) > 0
  end

  local function farmTargetIsBossChest(target)
      return BossChestNames[normalizeCoinName(getFarmTargetName(target))] == true
  end

  local function collectFarmTargets()
      local targets = {}
      if serverCoinSnapshotReady then
          for _, record in pairs(serverCoinRecords) do
              if farmTargetCanBeUsed(record) then table.insert(targets, record) end
          end
          return targets
      end

      local folder = refreshCoinsFolderReference()
      if folder then
          for _, coin in ipairs(folder:GetChildren()) do
              if farmTargetCanBeUsed(coin) then table.insert(targets, coin) end
          end
      end
      return targets
  end

  local function getOrderedFarmTargets(strongestFirst, claimedIds, rejectedIds, filter)
      local targets = {}
      for _, target in ipairs(collectFarmTargets()) do
          local targetId = tostring(getFarmTargetId(target) or "")
          if targetId ~= ""
              and not (claimedIds and claimedIds[targetId])
              and not (rejectedIds and rejectedIds[targetId])
              and (not filter or filter(target)) then
              table.insert(targets, target)
          end
      end

      table.sort(targets, function(left, right)
          local leftHealth = getFarmTargetCurrentHealth(left)
          local rightHealth = getFarmTargetCurrentHealth(right)
          if leftHealth ~= rightHealth then
              return strongestFirst and leftHealth > rightHealth or not strongestFirst and leftHealth < rightHealth
          end

          local leftMax = getFarmTargetMaxHealth(left)
          local rightMax = getFarmTargetMaxHealth(right)
          if leftMax ~= rightMax then
              return strongestFirst and leftMax > rightMax or not strongestFirst and leftMax < rightMax
          end
          return tostring(getFarmTargetId(left)) < tostring(getFarmTargetId(right))
      end)
      return targets
  end

  local function getRegularTargetOrder(strongestFirst, claimedIds, rejectedIds, minimumMaxHealth)
      return getOrderedFarmTargets(strongestFirst, claimedIds, rejectedIds, function(target)
          return not farmTargetIsBossChest(target)
              and (not minimumMaxHealth or getFarmTargetMaxHealth(target) >= minimumMaxHealth)
      end)
  end

  local function getBossTargetOrder(rejectedIds)
      return getOrderedFarmTargets(true, nil, rejectedIds, farmTargetIsBossChest)
  end

  local function getBigTargetMinimumHealth()
      local largestMaxHealth = 0
      for _, target in ipairs(getRegularTargetOrder(true)) do
          largestMaxHealth = math.max(largestMaxHealth, getFarmTargetMaxHealth(target))
      end
      if largestMaxHealth <= 0 then return nil end
      local threshold = math.clamp(tonumber(_G.BigCoinThreshold) or 65, 10, 100) / 100
      return largestMaxHealth * threshold
  end

  local function findFarmTargetById(targetId)
      targetId = tostring(targetId)
      local record = serverCoinRecords[targetId]
      if record and farmTargetIsAlive(record) then return record end

      local folder = refreshCoinsFolderReference()
      if not folder then return nil end
      local direct = folder:FindFirstChild(targetId)
      if direct and farmTargetIsAlive(direct) then return direct end
      for _, coin in ipairs(folder:GetChildren()) do
          if tostring(getCoinNetworkId(coin)) == targetId and farmTargetIsAlive(coin) then
              return coin
          end
      end
      return nil
  end

  local function readAuthoritativePetTargets(equippedPetSet)
      local petTargets, occupiedTargetIds = {}, {}
      if serverCoinSnapshotReady then
          local targetIds = {}
          for targetId in pairs(serverCoinRecords) do table.insert(targetIds, targetId) end
          table.sort(targetIds)
          for _, targetId in ipairs(targetIds) do
              local record = serverCoinRecords[targetId]
              if farmTargetIsAlive(record) then
                  for petId in pairs(record.PetSet or {}) do
                      petId = tostring(petId)
                      if equippedPetSet[petId] and not petTargets[petId] then
                          petTargets[petId] = record
                          occupiedTargetIds[targetId] = true
                      end
                  end
              end
          end
          return petTargets, occupiedTargetIds
      end

      local folder = refreshCoinsFolderReference()
      if not folder then return petTargets, occupiedTargetIds end
      for _, coin in ipairs(folder:GetChildren()) do
          local pets = coin:FindFirstChild("Pets")
          if pets and farmTargetIsAlive(coin) then
              for _, marker in ipairs(pets:GetChildren()) do
                  local idObject = marker:FindFirstChild("ID_Attr")
                  local petId = idObject and tostring(idObject.Value)
                      or tostring(marker:GetAttribute("ID_Attr") or marker:GetAttribute("ID") or marker.Name)
                  if equippedPetSet[petId] then
                      petTargets[petId] = coin
                      occupiedTargetIds[tostring(getFarmTargetId(coin))] = true
                  end
              end
          end
      end
      return petTargets, occupiedTargetIds
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

      if os.clock() - lastPetRuntimeScan < 0.25 then return nil end
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

  local function bindLocalPetTargetByUID(petId, target)
      local coin = getFarmTargetModel(target)
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

  local function localPetArrivedAtCoin(petId, target)
      local coin = getFarmTargetModel(target)
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
  
  local function syncPetTargetByUID(petId, target)
      local library = getPSXLibrary()
      local network = library and library.Network
      if not network or type(network.Fire) ~= "function" then return false end

      petId = tostring(petId)
      local coinId = getFarmTargetId(target)
      if not coinId then return false end

      return pcall(network.Fire, "Change Pet Target", petId, "Coin", coinId)
  end

  local function fireFarmCoinByUID(petId, target)
      local library = getPSXLibrary()
      local network = library and library.Network
      if not network or type(network.Fire) ~= "function" then return false end

      local coinId = getFarmTargetId(target)
      if not coinId then return false end
      return pcall(network.Fire, "Farm Coin", coinId, tostring(petId))
  end

  local function joinPetsToCoinByUID(target, petIds)
      local acceptedPets = {}
      local library = getPSXLibrary()
      local network = library and library.Network
      if not network
          or type(network.Invoke) ~= "function"
          or type(network.Fire) ~= "function"
          or not target
          or #petIds == 0 then
          return acceptedPets
      end

      local coinId = getFarmTargetId(target)
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
                      elseif tostring(responseValue) == petId then
                          accepted = true
                          break
                      end
                  end
              end
            acceptedPets[petId] = accepted ~= nil and accepted ~= false
          end
      end

      return acceptedPets
  end
  
  getCoinHealth = function(coin)
      local healthObject = coin:FindFirstChild("Health_Attr")
      if healthObject then
          local success, value = pcall(function() return healthObject.Value end)
          if success then return tonumber(value) or 0 end
      end
      return tonumber(coin:GetAttribute("Health_Attr")
          or coin:GetAttribute("Health")) or 0
  end

  local CoinPeakHealth = setmetatable({}, { __mode = "k" })

  getCoinPriorityHealth = function(coin)
      local currentHealth = getCoinHealth(coin)
      local peakHealth = math.max(CoinPeakHealth[coin] or 0, currentHealth)
      CoinPeakHealth[coin] = peakHealth
      return peakHealth
  end
  
  readCoinBool = function(coin, name)
      local object = coin:FindFirstChild(name .. "_Attr")
      if object then
          local success, value = pcall(function() return object.Value end)
          if success then return value end
      end
      local value = coin:GetAttribute(name .. "_Attr")
      if value ~= nil then return value end
      return coin:GetAttribute(name)
  end
  
  coinCanBeFarmed = function(coin)
      if not coin or not coin.Parent or not coin:FindFirstChild("POS") then return false end
      if getCoinHealth(coin) <= 0 then return false end
      if readCoinBool(coin, "IsFalling") == true then return false end
      if readCoinBool(coin, "HasLanded") == false then return false end
      return true
  end
  
  getCoinName = function(coin)
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

  normalizeCoinName = function(name)
      name = string.lower(tostring(name or ""))
      name = string.gsub(name, "[%p_]+", " ")
      name = string.gsub(name, "%s+", " ")
      return string.match(name, "^%s*(.-)%s*$") or name
  end

  -- Только постоянные гигантские/AFK-сундуки из конечных зон.
  -- Обычные случайные Chest (например Enchanted Forest Chest) сюда не входят.
  BossChestNames = {
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

-- Событийный UID-распределитель. После успешного Join Coin цель неизменна до
-- Update Coin Health <= 0 / Remove Coin, поэтому питомцы не меняются монетами.
task.spawn(function()
    local petStates = {}
    local rejectedTargetIds = {}
    local lockedGroupTargetId = nil
    local previousMode = _G.PetFarmMode
    local previousContext = nil
    local allocatorWasEnabled = false
    local requestSerial = 0
    local cachedPetIds = {}
    local cachedEquippedPetSet = {}
    local nextPetRefreshAt = 0

    local JOIN_RETRY_DELAY = 0.12
    local MAX_JOIN_ATTEMPTS = 3
    local FAILURE_COOLDOWN = 0.3
    local PET_REFRESH_INTERVAL = 0.5
    local MAX_TARGET_SENDS = 2
    local MAX_FARM_SENDS = 2

    local function releasePetState(petId)
        petStates[tostring(petId)] = nil
    end

    local function resetTransientState()
        table.clear(rejectedTargetIds)
        lockedGroupTargetId = nil
    end

    local function resetAllState()
        table.clear(petStates)
        table.clear(cachedPetIds)
        table.clear(cachedEquippedPetSet)
        nextPetRefreshAt = 0
        resetTransientState()
    end

    local function targetContainsPet(target, petId)
        return isServerCoinRecord(target)
            and target.PetSet
            and target.PetSet[tostring(petId)] == true
    end

    local function createReservedState(petId, target)
        petId = tostring(petId)
        local state = {
            Target = target,
            TargetId = tostring(getFarmTargetId(target)),
            Phase = "reserved",
            JoinAttempts = 0,
            TargetSends = 0,
            FarmSends = 0,
            LocalBound = false,
            MembershipConfirmed = false
        }
        petStates[petId] = state
        return state
    end

    local function lockAcceptedPet(petId, state, target, now)
        state.Phase = "locked"
        state.AcceptedAt = now
        state.MembershipConfirmed = state.MembershipConfirmed or targetContainsPet(target, petId)
        state.LocalBound = bindLocalPetTargetByUID(petId, target)

        state.TargetSends = state.TargetSends + 1
        state.TargetSent = syncPetTargetByUID(petId, target)
        state.NextTargetSendAt = now + 0.15

        state.FarmSends = state.FarmSends + 1
        state.ImmediateFarmSent = fireFarmCoinByUID(petId, target)
        state.NextFarmSendAt = now + 0.2
        state.ArrivalFarmSent = false
    end

    local function dispatchPetsToTarget(petIds, target)
        if not farmTargetIsAlive(target) or #petIds == 0 then return end
        local targetId = tostring(getFarmTargetId(target))
        local requestTokens = {}

        for _, rawPetId in ipairs(petIds) do
            local petId = tostring(rawPetId)
            local state = petStates[petId] or createReservedState(petId, target)
            if state.TargetId == targetId and state.Phase ~= "joining" then
                requestSerial = requestSerial + 1
                state.Phase = "joining"
                state.RequestId = requestSerial
                state.JoinAttempts = (tonumber(state.JoinAttempts) or 0) + 1
                requestTokens[petId] = requestSerial
            end
        end

        local requestedPetIds = {}
        for petId in pairs(requestTokens) do table.insert(requestedPetIds, petId) end
        if #requestedPetIds == 0 then return end
        table.sort(requestedPetIds)

        task.spawn(function()
            local acceptedPets = joinPetsToCoinByUID(target, requestedPetIds)
            local finishedAt = os.clock()
            local acceptedAny = false

            for _, petId in ipairs(requestedPetIds) do
                local state = petStates[petId]
                if state
                    and state.TargetId == targetId
                    and state.RequestId == requestTokens[petId] then
                    local accepted = acceptedPets[petId]
                        or state.MembershipConfirmed
                        or targetContainsPet(target, petId)

                    if accepted and _G.AutoPetCoins and isScriptRunning() and farmTargetIsAlive(target) then
                        acceptedAny = true
                        lockAcceptedPet(petId, state, target, finishedAt)
                    elseif farmTargetIsAlive(target)
                        and state.JoinAttempts < MAX_JOIN_ATTEMPTS
                        and _G.AutoPetCoins then
                        state.Phase = "retry"
                        state.RetryAt = finishedAt + JOIN_RETRY_DELAY
                    else
                        releasePetState(petId)
                    end
                end
            end

            if not acceptedAny and farmTargetIsAlive(target) then
                rejectedTargetIds[targetId] = finishedAt + FAILURE_COOLDOWN
                if lockedGroupTargetId == targetId then lockedGroupTargetId = nil end
            end
            wakePetAllocator()
        end)
    end

    while isScriptRunning() do
        if not _G.AutoPetCoins then
            if allocatorWasEnabled then
                resetAllState()
                previousMode = _G.PetFarmMode
                previousContext = nil
                allocatorWasEnabled = false
            end
            task.wait(0.05)
            continue
        end

        RunService.Heartbeat:Wait()
        if not isScriptRunning() then break end
        allocatorWasEnabled = true

        ensureServerCoinNetwork()
        local now = os.clock()
        if not serverCoinFetchInFlight
            and (serverCoinFetchRequested or now >= serverCoinNextFetchAt) then
            task.spawn(refreshServerCoinSnapshot)
        end

        local mode = _G.PetFarmMode or "DifferentStrongest"
        local context = getFarmContextKey()
        if mode ~= previousMode or context ~= previousContext then
            -- Активные назначения не трогаем: новая стратегия влияет только на свободных питомцев.
            resetTransientState()
            previousMode = mode
            previousContext = context
        end

        if now >= nextPetRefreshAt then
            nextPetRefreshAt = now + PET_REFRESH_INTERVAL
            table.clear(cachedPetIds)
            table.clear(cachedEquippedPetSet)
            for _, rawPetId in ipairs(getEquippedPetIds()) do
                local petId = tostring(rawPetId)
                table.insert(cachedPetIds, petId)
                cachedEquippedPetSet[petId] = true
            end
            table.sort(cachedPetIds)
        end

        if #cachedPetIds == 0 then
            resetAllState()
            continue
        end

        for targetId, expiresAt in pairs(rejectedTargetIds) do
            if now >= expiresAt or not farmTargetIsAlive(findFarmTargetById(targetId)) then
                rejectedTargetIds[targetId] = nil
            end
        end

        -- Единственные причины снять блокировку: питомец снят или монета уничтожена.
        for petId, state in pairs(petStates) do
            if not cachedEquippedPetSet[petId] or not farmTargetIsAlive(state.Target) then
                releasePetState(petId)
            end
        end

        local livePetTargets, occupiedTargetIds = readAuthoritativePetTargets(cachedEquippedPetSet)
        for petId, liveTarget in pairs(livePetTargets) do
            local liveTargetId = tostring(getFarmTargetId(liveTarget))
            local state = petStates[petId]
            if not state then
                -- Назначение существовало до запуска скрипта: принимаем его и не дублируем remotes.
                state = createReservedState(petId, liveTarget)
                state.Phase = "locked"
                state.MembershipConfirmed = true
                state.TargetSends = MAX_TARGET_SENDS
                state.FarmSends = MAX_FARM_SENDS
                state.ArrivalFarmSent = true
                state.LocalBound = bindLocalPetTargetByUID(petId, liveTarget)
            elseif state.TargetId == liveTargetId then
                state.MembershipConfirmed = true
                if state.Phase == "joining" or state.Phase == "retry" then
                    state.Phase = "locked"
                end
            end
            -- Конфликтующее событие не заменяет живую state.Target: это устраняет обмен целями.
        end

        for petId, state in pairs(petStates) do
            if state.Phase == "retry" and now >= (state.RetryAt or 0) then
                dispatchPetsToTarget({ petId }, state.Target)
            elseif state.Phase == "locked" then
                if not state.LocalBound then
                    state.LocalBound = bindLocalPetTargetByUID(petId, state.Target)
                end

                if state.TargetSends < MAX_TARGET_SENDS
                    and now >= (state.NextTargetSendAt or 0) then
                    state.TargetSends = state.TargetSends + 1
                    state.TargetSent = syncPetTargetByUID(petId, state.Target) or state.TargetSent
                    state.NextTargetSendAt = math.huge
                end

                local arrived = localPetArrivedAtCoin(petId, state.Target)
                if arrived and not state.ArrivalFarmSent then
                    state.ArrivalFarmSent = true
                    fireFarmCoinByUID(petId, state.Target)
                elseif state.FarmSends < MAX_FARM_SENDS
                    and now >= (state.NextFarmSendAt or 0) then
                    state.FarmSends = state.FarmSends + 1
                    fireFarmCoinByUID(petId, state.Target)
                    state.NextFarmSendAt = math.huge
                end
            end
        end

        local freePetIds = {}
        for _, petId in ipairs(cachedPetIds) do
            if not petStates[petId] and not livePetTargets[petId] then
                table.insert(freePetIds, petId)
            end
        end
        if #freePetIds == 0 then continue end

        local isGroupMode = mode == "AllOneBossChest" or mode == "AllOneBigCoin"
        if isGroupMode then
            local lockedTarget = lockedGroupTargetId and findFarmTargetById(lockedGroupTargetId) or nil
            if not farmTargetIsAlive(lockedTarget) then
                lockedTarget = nil
                lockedGroupTargetId = nil
            end

            if not lockedTarget then
                for _, state in pairs(petStates) do
                    local targetMatchesMode = mode == "AllOneBossChest"
                        and farmTargetIsBossChest(state.Target)
                        or mode == "AllOneBigCoin"
                        and not farmTargetIsBossChest(state.Target)
                    if targetMatchesMode and farmTargetIsAlive(state.Target) then
                        lockedTarget = state.Target
                        lockedGroupTargetId = state.TargetId
                        break
                    end
                end
            end

            if not lockedTarget then
                local orderedTargets
                if mode == "AllOneBossChest" then
                    orderedTargets = getBossTargetOrder(rejectedTargetIds)
                else
                    local minimumMaxHealth = getBigTargetMinimumHealth()
                    orderedTargets = minimumMaxHealth
                        and getRegularTargetOrder(true, nil, rejectedTargetIds, minimumMaxHealth)
                        or {}
                end
                lockedTarget = orderedTargets[1]
                lockedGroupTargetId = lockedTarget and tostring(getFarmTargetId(lockedTarget)) or nil
            end

            if lockedTarget then
                for _, petId in ipairs(freePetIds) do createReservedState(petId, lockedTarget) end
                dispatchPetsToTarget(freePetIds, lockedTarget)
            end
            continue
        end

        local claimedTargetIds = {}
        for targetId in pairs(occupiedTargetIds) do claimedTargetIds[targetId] = true end
        for _, state in pairs(petStates) do
            if farmTargetIsAlive(state.Target) then claimedTargetIds[state.TargetId] = true end
        end

        local strongestFirst = mode ~= "DifferentWeakest"
        local uniqueTargets = getRegularTargetOrder(
            strongestFirst,
            claimedTargetIds,
            rejectedTargetIds
        )
        local sharedTargets = nil
        local sharedIndex = 1
        local dispatchPlans = {}

        for _, petId in ipairs(freePetIds) do
            local target = table.remove(uniqueTargets, 1)
            if not target then
                -- Если целей меньше, чем питомцев, оставшиеся делят лучшие доступные цели,
                -- чтобы режим «по разным» не превращался в простой части команды.
                sharedTargets = sharedTargets or getRegularTargetOrder(
                    strongestFirst,
                    nil,
                    rejectedTargetIds
                )
                if #sharedTargets > 0 then
                    target = sharedTargets[((sharedIndex - 1) % #sharedTargets) + 1]
                    sharedIndex = sharedIndex + 1
                end
            end

            if target then
                local targetId = tostring(getFarmTargetId(target))
                createReservedState(petId, target)
                claimedTargetIds[targetId] = true
                local plan = dispatchPlans[targetId]
                if not plan then
                    plan = { Target = target, Pets = {} }
                    dispatchPlans[targetId] = plan
                end
                table.insert(plan.Pets, petId)
            end
        end

        for _, plan in pairs(dispatchPlans) do
            dispatchPetsToTarget(plan.Pets, plan.Target)
        end
    end
end)
bootTrace("16 pet allocator registered")


local function countFarmableTargetsInZone()
    return #collectFarmTargets()
end

task.spawn(function()
    while task.wait(_G.AutoPetCoins and 0.5 or 2) do
        if not isScriptRunning() then break end
        if not _G.AutoPetCoins and not _G.AutoFarm then
            setDescriptionCached(currentZoneParagraph, "Farm is disabled — zone scanning is paused", 2)
            continue
        end

        refreshZoneDropdown(false)
        local loadedWorld = getCurrentWorldName()
        local selectedWorld = getSelectedFarmWorld() or "unknown world"
        local zoneName = getSelectedFarmZone() or "unknown zone"
        local targetCount = countFarmableTargetsInZone()
        local targetSource = serverCoinSnapshotReady and "Get Coins" or "Workspace fallback"
        setDescriptionCached(
            currentZoneParagraph,
            "Loaded: " .. loadedWorld
                .. " | filter: " .. selectedWorld .. " / " .. zoneName
                .. " | targets: " .. tostring(targetCount)
                .. " | source: " .. targetSource,
            1
        )
    end
end)

task.spawn(function()
    while task.wait(0.2) do
          if not isScriptRunning() then break end
          if not _G.AutoOrbs and not _G.AutoLootbags then continue end
  
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
      while task.wait(_G.AutoEgg and 1 or 3) do
          if not isScriptRunning() then break end
          if _G.AutoEgg then refreshEggDropdown(false) end
      end
  end)

  task.spawn(function()
      while task.wait(_G.AutoBoosts and 0.25 or 2) do
          if not isScriptRunning() then break end

          if not _G.AutoBoosts then
              setDescriptionCached(boostStatusParagraph, "Auto boost is disabled", 2)
              continue
          end

          local saveData = getSaveData()
          local library = getPSXLibrary()
          local statusLines = {}

          if not saveData then
              table.insert(statusLines, "Library.Save is not loaded yet")
          else
              local activeBoosts = type(saveData.Boosts) == "table" and saveData.Boosts or {}
              local boostInventory = type(saveData.BoostsInventory) == "table" and saveData.BoostsInventory or {}
              local isTradingPlaza = library and library.Shared and library.Shared.IsTradingPlaza == true
              local now = os.clock()
              table.insert(statusLines, string.format(
                  "Primary: Network.Fire | fallback: remote [%s], %s",
                  tostring(boostDirectRemoteIndex or "?"),
                  tostring(boostDirectRemoteSource)
              ))

              local boostSentThisTick = false
              for _, definition in ipairs(boostDefinitions) do
                  local boostName = resolveBoostName(saveData, definition)
                  local remaining = tonumber(activeBoosts[boostName]) or 0
                  local inventoryCount = tonumber(boostInventory[boostName]) or 0
                  local enabled = _G.EnabledBoosts[definition.key] == true
                  local state = "waiting"
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
                      state = "activation confirmed by Save"
                  elseif not enabled then
                      state = "disabled"
                  elseif not _G.AutoBoosts then
                      state = "auto boost disabled"
                  elseif isTradingPlaza then
                      state = "paused in Trading Plaza"
                  elseif inventoryCount <= 0 then
                      state = "not in inventory"
                  elseif remaining > (tonumber(_G.BoostRenewBefore) or 5) then
                      state = "waiting for renewal window"
                  elseif pending then
                      state = "command sent; waiting for Save"
                  elseif now < (boostNextAttempt[definition.key] or 0) then
                      state = "short pause after confirmation"
                  elseif boostSentThisTick then
                      state = "queued for next cycle"
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
                          state = "sent through " .. tostring(sendMethod) .. "; waiting for Save"
                      else
                          state = "send failed: " .. tostring(sendMethod)
                          boostNextAttempt[definition.key] = now + 0.75
                      end
                  end

                  table.insert(statusLines, string.format(
                      "%s: %s | inventory %d | %s%s",
                      definition.title,
                      formatBoostTime(remaining),
                      inventoryCount,
                      state,
                      boostLastConfirmedMethod[definition.key]
                          and (" | last: " .. boostLastConfirmedMethod[definition.key])
                          or ""
                  ))
              end
          end

          setDescriptionCached(boostStatusParagraph, table.concat(statusLines, "\n"), 1)
      end
  end)


  local function setEggStatus(text)
      eggStatusText = tostring(text or "")
      setDescriptionCached(eggStatusParagraph, eggStatusText, 0.05)
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
                  "Server opened: %s | waiting for the normal animation to finish",
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
              setEggStatus("First Open Egg received — fast mode enabled")
              return
          end

          setEggAnimationGate(true)
          pcall(network.Fire, "Opening Egg", eggId, pets)
          setEggStatus(string.format(
              "Fast opened: %s | server events %d",
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
  local fastEggListenerInstalled = false
  local nextFastEggListenerAttempt = 0

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
              setEggStatus("Auto open enabled — preparing Buy Egg Yay...")
          else
              eggRequestSequence = eggRequestSequence + 1
              eggRequestInFlight = false
              setEggStatus("Auto open disabled")
          end
      end
  end

  task.spawn(function()
      while task.wait(_G.AutoEgg and 0.03 or 0.5) do
          if not isScriptRunning() then break end

          syncEggToggleState()
          local now = os.clock()

          if _G.AutoEgg
              and not fastEggListenerInstalled
              and now >= nextFastEggListenerAttempt then
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
                  and "Timeout: Open Egg arrived but Buy Egg Yay did not finish; auto open stopped"
                  or "Timeout: the server did not send Open Egg; auto open stopped")
          end

          if _G.AutoEgg and not eggRequestInFlight and now >= nextEggRequestAt then
              if _G.SkipAnim and not fastEggListenerInstalled then
                  setEggStatus("Waiting for Library.Network.Fired(\"Open Egg\")...")
                  continue
              end

              local library = getPSXLibrary()
              local openingEgg = library and library.Variables and library.Variables.OpeningEgg == true

              -- Штатный Open Eggs отбрасывает новые события, пока идёт предыдущая анимация.
              -- Быстрый режим обрабатывает Open Egg сам; обычный обязан дождаться OpeningEgg=false.
              if openingEgg and not _G.SkipAnim then
                  setEggStatus("Waiting for the current egg animation to finish...")
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
                  "Sending Buy Egg Yay: %s (%s)",
                  tostring(targetEgg),
                  triple and "x3" or "x1"
              ))

              task.spawn(function()
                  local workerOk, success, message = pcall(openEgg, targetEgg, triple)
                  if requestId ~= eggRequestSequence then return end

                  if not workerOk then
                      setEggStatus("openEgg failed: " .. tostring(success))
                      nextEggRequestAt = math.max(nextEggRequestAt, os.clock() + 0.5)
                  elseif success then
                      setEggStatus(tostring(message) .. " — " .. tostring(targetEgg))
                  else
                      setEggStatus(tostring(message or "Server rejected the egg purchase"))
                      -- Ошибки покупки (дистанция, валюта, геймпасс) не спамим каждый кадр.
                      nextEggRequestAt = math.max(nextEggRequestAt, os.clock() + 0.5)
                  end

                  eggRequestInFlight = false
              end)
          elseif not _G.AutoEgg and eggStatusText ~= "Auto open disabled" then
              setEggAnimationGate(false)
              setEggStatus("Auto open disabled")
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
      if not shouldBlockAnimation then return end

      pcall(function()
          local library = getPSXLibrary()
          if library and library.Variables then
              -- Open Eggs.lua сразу выходит из обработчика "Open Egg", когда флаг уже true.
              library.Variables.OpeningEgg = true
          end

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
      local lastIdleText = nil
  
      while task.wait(1) do
          if not isScriptRunning() then break end
  
          if lastCurrencyName ~= _G.TrackedCurrency then
              lastCurrencyName = _G.TrackedCurrency
              table.clear(currencySamples)
          end
  
          if not _G.AutoFarm and not _G.AutoPetCoins then
              table.clear(currencySamples)

              local idleText = _G.TrackedCurrency .. "/min: farm disabled"
              if currencyTrackerLabel and idleText ~= lastIdleText then
                  local updated = pcall(function() currencyTrackerLabel:Set(idleText) end)
                  if updated then lastIdleText = idleText end
              end
              continue
          end

          lastIdleText = nil
          local targetCount = countFarmableTargetsInZone()
          local currentAmount = getCurrentCurrency(_G.TrackedCurrency)
  
              if currentAmount == nil then
                  table.clear(currencySamples)
  
                  if currencyTrackerLabel then
                      pcall(function()
                          currencyTrackerLabel:Set(
                              _G.TrackedCurrency .. "/min: currency not found"
                              .. " | zone targets: " .. tostring(targetCount)
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
                                  _G.TrackedCurrency .. "/min: collecting data..."
                                  .. " | zone targets: " .. tostring(targetCount)
                              )
                          else
                              currencyTrackerLabel:Set(
                                  _G.TrackedCurrency .. "/min: " .. formatCurrency(perMinute)
                                  .. " | gained: +" .. formatCurrency(gained)
                                  .. " | zone targets: " .. tostring(targetCount)
                              )
                          end
                      end)
                  end
              end
      end
  end)
  bootTrace("17 background workers registered")
  
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
  bootTrace("18 startup complete")
