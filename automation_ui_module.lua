-- Lazy automation UI extension for LowOnline through the first Fantasy update.
-- Keeps optional automation controls outside the main executor chunk.

local MODULE_VERSION = "1.6.5-lowonline"

local function requireKeys(context, keys)
    if type(context) ~= "table" then return false, "UI context is missing" end
    for _, key in ipairs(keys) do
        if context[key] == nil then return false, "UI context is missing " .. key end
    end
    return true
end

local function build(context)
    local valid, problem = requireKeys(context, {
        "UI", "Config", "StatusViews", "RefreshEggs", "EnsureAutoEgg",
        "InvalidateEggCatalog", "StartAutoEgg", "StopAutoEgg", "EggIdForLabel",
        "SetEggCatalogStatus",
        "RefreshRoutes", "SetRouteStatus", "GetMachinePetCatalog", "StartMachine",
        "StopMachine", "SetGoldStatus", "SetRainbowStatus", "SetDarkMatterStatus",
        "SetFuseStatus", "GetEnchantCatalog", "SetEnchantStatus",
        "ReconcileBoost", "BoostEnabled", "StartBoost",
    })
    if not valid then return false, problem end

    local UI = context.UI
    local config = context.Config
    local statusViews = context.StatusViews
    local spawn = type(context.Task) == "table" and context.Task.spawn or task.spawn
    local yieldUI = type(context.YieldUI) == "function" and context.YieldUI or function() end

    local eggCatalog = UI.EggTab:Section({ Title = "01 / Live Egg Catalog", Box = true, Opened = true })
    eggCatalog:Paragraph({
        Title = "LOCAL DISCOVERY / ZERO PROBES",
        Desc = "Reads Library.Directory.Eggs and the current __MAP without purchasing.",
    })
    local eggScope = eggCatalog:Dropdown({
        Flag = "egg_catalog_scope",
        Title = "Catalog Scope",
        Desc = "Nearby lists eggs loaded in the current world; distance does not block purchases.",
        Values = { "Nearby Eggs", "All Hatchable Eggs" },
        Value = "Nearby Eggs",
        Multi = false,
        AllowNone = false,
        Callback = function(value)
            config.EggScope = value == "All Hatchable Eggs" and "All Hatchable Eggs" or "Nearby Eggs"
            context.RefreshEggs(true)
        end,
    })
    local eggDropdown = eggCatalog:Dropdown({
        Flag = "selected_egg",
        Title = "Egg",
        Desc = "The selected egg stays fixed while auto hatch is active.",
        Values = { "Egg catalog loads on demand..." },
        Value = "Egg catalog loads on demand...",
        Multi = false,
        AllowNone = false,
        Callback = function(value)
            local eggId = context.EggIdForLabel(value)
            if eggId then config.EggName = eggId end
        end,
    })
    eggCatalog:Button({
        Title = "REFRESH LOCAL CATALOG",
        Desc = "Loads the egg worker and re-indexes local models; no server request.",
        Icon = "refresh-cw",
        Callback = function()
            spawn(function()
                local loaded, loadProblem = context.EnsureAutoEgg()
                if not loaded then
                    context.SetEggCatalogStatus("Catalog module could not be loaded: " .. tostring(loadProblem))
                    return
                end
                context.InvalidateEggCatalog()
                context.RefreshEggs(true)
            end)
        end,
    })
    statusViews.EggCatalog = eggCatalog:Paragraph({
        Title = "Catalog Status",
        Desc = "Catalog is lazy-loaded to keep startup stable.",
    })
    yieldUI("egg catalog")

    local eggAutomation = UI.EggTab:Section({ Title = "02 / Protocol-Safe Hatch Loop", Box = true, Opened = true })
    eggAutomation:Paragraph({
        Title = "PREFLIGHT > BUY > ACK > COOLDOWN",
        Desc = "One request in flight. Headless confirms Open Egg or an exact inventory delta.",
    })
    eggAutomation:Dropdown({
        Flag = "egg_open_count",
        Title = "Eggs Per Purchase",
        Desc = "x3 requires Triple Egg Open and three free inventory slots.",
        Values = { "Single (x1)", "Triple (x3)" },
        Value = "Single (x1)",
        Multi = false,
        AllowNone = false,
        Callback = function(value) config.EggCount = value == "Triple (x3)" and 3 or 1 end,
    })
    eggAutomation:Dropdown({
        Flag = "egg_animation_mode",
        Title = "Animation Mode",
        Desc = "Headless suppresses visuals; Native uses the game's live skip path.",
        Values = { "Headless (No Animation)", "Native Animation" },
        Value = "Headless (No Animation)",
        Multi = false,
        AllowNone = false,
        Callback = function(value)
            config.EggAnimation = value == "Native Animation" and "Native Animation"
                or "Headless (No Animation)"
        end,
    })
    local eggPaceMode = eggAutomation:Dropdown({
        Flag = "egg_pace_mode",
        Title = "Request Pace",
        Desc = "Adaptive learns from confirmed hatches; Manual uses the exact delay below. Both keep one request in flight.",
        Values = { "Adaptive (History)", "Manual Delay" },
        Value = "Adaptive (History)",
        Multi = false,
        AllowNone = false,
        Callback = function(value)
            config.EggPaceMode = value == "Manual Delay" and "Manual Delay" or "Adaptive (History)"
        end,
    })
    local eggManualDelay = eggAutomation:Slider({
        Flag = "egg_manual_delay_ms",
        Title = "Manual Hatch Delay",
        Desc = "Milliseconds after a confirmed hatch. Minimum 50ms; server replies still control the real maximum speed.",
        Step = 25,
        Value = { Min = 50, Max = 3000, Default = 100 },
        Callback = function(value)
            config.EggManualDelayMs =
                math.clamp(math.floor(tonumber(value) or 100), 50, 3000)
        end,
    })
    local autoEggToggle = eggAutomation:Toggle({
        Flag = "auto_egg",
        Title = "Enable Auto Hatch",
        Desc = "Requires the selected egg to be loaded in the current world; there is no client distance limit.",
        Value = false,
        Callback = function(value)
            local enabled = value == true
            if config.AutoEgg == enabled then return end
            config.AutoEgg = enabled
            if enabled then
                spawn(context.StartAutoEgg)
            else
                context.StopAutoEgg("Auto hatch disabled. No egg request is active.")
            end
        end,
    })
    statusViews.Egg = eggAutomation:Paragraph({
        Title = "Hatch Controller",
        Desc = "Disabled | live Network routes resolve only for a valid purchase.",
    })
    yieldUI("egg automation")

    local routes = UI.MonitorTab:Section({ Title = "Live Protocol Health", Box = true, Opened = true })
    routes:Paragraph({
        Title = "SESSION-SAFE ROUTES",
        Desc = "Named commands resolve per session; child indices are diagnostics only.",
    })
    routes:Button({
        Title = "REFRESH COMMAND STATUS",
        Desc = "Manual local lookup through Library.Network; never invokes the server.",
        Icon = "refresh-cw",
        Callback = function() spawn(context.RefreshRoutes) end,
    })
    statusViews.Routes = routes:Paragraph({
        Title = "Command Status",
        Desc = "Manual diagnostics are idle. Press Refresh when needed.",
    })
    yieldUI("route diagnostics")

    local machines = UI.MachinesTab:Section({ Title = "Safe Conversion Pipeline", Box = true, Opened = true })
    machines:Paragraph({
        Title = "NORMAL > GOLD > RAINBOW > DARK MATTER",
        Desc = "Gold/Rainbow target Samurai Dragon; Dark Matter keeps Domortuus. Every batch is rebuilt from a fresh Save snapshot.",
    })
    machines:Slider({
        Flag = "machine_batch_size",
        Title = "Gold / Rainbow Pets Per Request",
        Desc = "Choose 1-6 matching pets for Golden and Rainbow requests.",
        Step = 1,
        Value = { Min = 1, Max = 6, Default = 6 },
        Callback = function(value)
            config.MachineBatchSize = math.clamp(math.floor(tonumber(value) or 6), 1, 6)
        end,
    })
    machines:Button({
        Title = "REFRESH SAMURAI DRAGON CATALOG",
        Desc = "Re-reads Directory.Pets locally; no machine request.",
        Icon = "refresh-cw",
        Callback = function()
            spawn(function()
                local _, _, summary = context.GetMachinePetCatalog(true)
                context.SetRouteStatus("Pet catalog refreshed locally: " .. tostring(summary))
            end)
        end,
    })
    yieldUI("machine controls")

    local fuse = UI.MachinesTab:Section({ Title = "Samurai Egg Fuse", Box = true, Opened = true })
    fuse:Paragraph({
        Title = "EXACT SPECIES BATCHES / LIVE DIRECTORY",
        Desc = "Panda x11, Axolotl x10, Tiger x9, any Rare x7 and any Epic x4. Every request contains one exact Samurai Egg species.",
    })
    local fuseModeToggles = {}
    local function enabledFuseModes()
        local modes = {}
        if config.AutoFusePanda then modes[#modes + 1] = "11 Panda" end
        if config.AutoFuseAxolotl then modes[#modes + 1] = "10 Axolotl" end
        if config.AutoFuseTiger then modes[#modes + 1] = "9 Tiger" end
        if config.AutoFuseRare then modes[#modes + 1] = "7 Any Rare" end
        if config.AutoFuseEpic then modes[#modes + 1] = "4 Any Epic" end
        return modes
    end
    local function reconcileFuseModes()
        local modes = enabledFuseModes()
        config.AutoFuse = #modes > 0
        if config.AutoFuse then
            context.SetFuseStatus("Enabled modes: " .. table.concat(modes, ", ")
                .. ". Batches run serially from fresh Save.Pets snapshots.")
            spawn(function() context.StartMachine("Fuse") end)
        else
            context.StopMachine("Fuse")
            context.SetFuseStatus("Disabled. No pets will be sent to the Fuse Machine.")
        end
    end
    for _, definition in ipairs({
        {
            Flag = "lowonline_fuse_panda",
            Key = "AutoFusePanda",
            Title = "Fuse 11 Panda",
            Desc = "Only exact Panda species from Samurai Egg; 11 normal pets per request.",
        },
        {
            Flag = "lowonline_fuse_axolotl",
            Key = "AutoFuseAxolotl",
            Title = "Fuse 10 Axolotl",
            Desc = "Only exact Axolotl species from Samurai Egg; 10 normal pets per request.",
        },
        {
            Flag = "lowonline_fuse_tiger",
            Key = "AutoFuseTiger",
            Title = "Fuse 9 Tiger",
            Desc = "Exact Tiger or White Tiger species from Samurai Egg; 9 normal pets per request.",
        },
        {
            Flag = "lowonline_fuse_rare",
            Key = "AutoFuseRare",
            Title = "Fuse 7 Any Rare",
            Desc = "Any Rare from Samurai Egg; each request still uses 7 pets of one exact species.",
        },
        {
            Flag = "lowonline_fuse_epic",
            Key = "AutoFuseEpic",
            Title = "Fuse 4 Any Epic",
            Desc = "Any Epic from Samurai Egg; each request still uses 4 pets of one exact species.",
        },
    }) do
        local item = definition
        fuseModeToggles[item.Key] = fuse:Toggle({
            Flag = item.Flag,
            Title = item.Title,
            Desc = item.Desc
                or "May run together with the other species modes; each request contains one exact species batch.",
            Value = false,
            Callback = function(value)
                config[item.Key] = value == true
                reconcileFuseModes()
            end,
        })
    end
    statusViews.Fuse = fuse:Paragraph({
        Title = "Fuse Machine Status",
        Desc = "Disabled / no pet UIDs have been selected",
    })
    yieldUI("fuse machine")

    local enchant = UI.MachinesTab:Section({
        Title = "Equipped Pet Enchanting",
        Box = true,
        Opened = true,
    })
    enchant:Paragraph({
        Title = "EQUIPPED ONLY / AUTHORITATIVE SAVE CONFIRMATION",
        Desc = "Selected enchants are OR alternatives. Each eligible equipped pet is rerolled serially until it has any selected result.",
    })
    local enchantPlaceholder = "Enchant catalog unavailable"
    local enchantValues = context.GetEnchantCatalog()
    if type(enchantValues) ~= "table" or #enchantValues == 0 then
        enchantValues = { enchantPlaceholder }
    end
    local enchantDropdown
    enchantDropdown = enchant:Dropdown({
        Flag = "equipped_enchant_targets",
        Title = "Accepted Enchants",
        Desc = "Choose one or more live Directory.Powers tier titles. No server request is sent while this list is empty.",
        Values = enchantValues,
        Value = {},
        Multi = true,
        AllowNone = true,
        Callback = function(values)
            local selected, seen = {}, {}
            for _, value in ipairs(type(values) == "table" and values or {}) do
                local label = type(value) == "table"
                    and (value.Title or value.title or value.Name) or value
                label = tostring(label or "")
                if label ~= "" and label ~= enchantPlaceholder and not seen[label] then
                    seen[label] = true
                    selected[#selected + 1] = label
                end
            end
            table.sort(selected)
            config.EnchantTargets = selected
            context.SetEnchantStatus(#selected > 0
                and ("Accepted results updated: " .. table.concat(selected, ", ")
                    .. ". The current pet is never interrupted.")
                or "Select at least one enchant. No Enchant Pet request is being sent.")
        end,
    })
    enchant:Button({
        Title = "REFRESH ENCHANT CATALOG",
        Desc = "Re-reads Library.Directory.Powers locally; no enchant request.",
        Icon = "refresh-cw",
        Callback = function()
            local values = context.GetEnchantCatalog()
            if type(values) == "table" and #values > 0 then
                enchantDropdown:Refresh(values)
                context.SetEnchantStatus("Catalog refreshed locally: "
                    .. tostring(#values) .. " selectable enchant tier(s).")
            else
                context.SetEnchantStatus(
                    "Library.Directory.Powers is unavailable; no enchant request was sent."
                )
            end
        end,
    })
    enchant:Toggle({
        Flag = "auto_enchant_equipped",
        Title = "Auto Enchant Equipped Pets",
        Desc = "Protects unequipped and locked pets; one equipped pet is rerolled at a time and confirmed from Save.Pets.",
        Value = false,
        Callback = function(value)
            config.AutoEnchantEquipped = value == true
            if config.AutoEnchantEquipped then
                context.SetEnchantStatus("Enabled. Validating selected enchants and equipped pets...")
                spawn(function() context.StartMachine("Enchant") end)
            else
                context.StopMachine("Enchant")
                context.SetEnchantStatus("Disabled. No Enchant Pet request is active.")
            end
        end,
    })
    statusViews.Enchant = enchant:Paragraph({
        Title = "Enchant Status",
        Desc = "Disabled / waiting for selected accepted enchants",
    })
    yieldUI("enchant worker")

    local gold = UI.MachinesTab:Section({ Title = "Golden Machine / Stage 1", Box = true, Opened = true })
    gold:Toggle({
        Flag = "auto_golden_galaxy_fox",
        Title = "Auto Golden Samurai Dragon",
        Desc = "Normal Samurai Dragon only; protects equipped and locked pets; enchants are not filtered.",
        Value = false,
        Callback = function(value)
            config.AutoGoldenGalaxyFox = value == true
            if config.AutoGoldenGalaxyFox then
                context.SetGoldStatus("Enabled. Loading the verified worker in the serial lane...")
                spawn(function() context.StartMachine("Gold") end)
            else
                context.StopMachine("Gold")
                context.SetGoldStatus("Disabled. No pets will be sent to the Golden Machine.")
            end
        end,
    })
    statusViews.Gold = gold:Paragraph({
        Title = "Golden Machine Status",
        Desc = "Disabled / waiting for a verified batch",
    })
    yieldUI("gold machine")

    local rainbow = UI.MachinesTab:Section({ Title = "Rainbow Machine / Stage 2", Box = true, Opened = true })
    rainbow:Toggle({
        Flag = "auto_rainbow_galaxy_fox",
        Title = "Auto Rainbow Samurai Dragon",
        Desc = "Golden Samurai Dragon only; protects equipped and locked pets; enchants are not filtered.",
        Value = false,
        Callback = function(value)
            config.AutoRainbowGalaxyFox = value == true
            if config.AutoRainbowGalaxyFox then
                context.SetRainbowStatus("Enabled. Loading the verified worker in the serial lane...")
                spawn(function() context.StartMachine("Rainbow") end)
            else
                context.StopMachine("Rainbow")
                context.SetRainbowStatus("Disabled. No pets will be sent to the Rainbow Machine.")
            end
        end,
    })
    statusViews.Rainbow = rainbow:Paragraph({
        Title = "Rainbow Machine Status",
        Desc = "Disabled / only golden target species are eligible",
    })
    yieldUI("rainbow machine")

    local darkMatter = UI.MachinesTab:Section({ Title = "Dark Matter Machine / Stage 3", Box = true, Opened = true })
    darkMatter:Slider({
        Flag = "dark_matter_batch_size",
        Title = "Dark Matter Pets Per Batch",
        Desc = "Minimum number of matching rainbow pets. This is independent from Gold/Rainbow.",
        Step = 1,
        Value = { Min = 1, Max = 6, Default = 6 },
        Callback = function(value)
            config.DarkMatterBatchSize = math.clamp(math.floor(tonumber(value) or 6), 1, 6)
            context.SetDarkMatterStatus(
                "Dark Matter policy updated: at least " .. tostring(config.DarkMatterBatchSize)
                    .. " pet(s) per batch. It applies to the next queue request."
            )
        end,
    })
    darkMatter:Slider({
        Flag = "dark_matter_max_wait_hours",
        Title = "Maximum Dark Matter Time (Hours)",
        Desc = "0 uses the exact pet count. A positive limit may add pets until the live server tier fits the time.",
        Step = 0.5,
        Value = { Min = 0, Max = 120, Default = 0 },
        Callback = function(value)
            config.DarkMatterMaxWaitHours = math.clamp(tonumber(value) or 0, 0, 120)
            local limit = config.DarkMatterMaxWaitHours
            context.SetDarkMatterStatus(limit > 0
                and ("Dark Matter policy updated: maximum " .. tostring(limit)
                    .. " hour(s). The live machine tiers may increase the pet count.")
                or ("Dark Matter policy updated: exact "
                    .. tostring(config.DarkMatterBatchSize or 6) .. "-pet tier; no time ceiling."))
        end,
    })
    darkMatter:Toggle({
        Flag = "auto_dark_matter_galaxy_fox",
        Title = "Auto Dark Matter Target Pets",
        Desc = "Rainbow targets; protects equipped and locked pets; enchants are not filtered.",
        Value = false,
        Callback = function(value)
            config.AutoDarkMatterGalaxyFox = value == true
            if config.AutoDarkMatterGalaxyFox or config.AutoClaimDarkMatter then
                context.SetDarkMatterStatus("Enabled. Loading the Dark Matter worker in the serial lane...")
                spawn(function() context.StartMachine("DarkMatter") end)
            else
                context.StopMachine("DarkMatter")
                context.SetDarkMatterStatus("Disabled. No Dark Matter requests will be sent.")
            end
        end,
    })
    darkMatter:Toggle({
        Flag = "auto_claim_dark_matter",
        Title = "Auto Claim Dark Matter Pets",
        Desc = "Redeems completed queue slots using server time, from any world.",
        Value = false,
        Callback = function(value)
            config.AutoClaimDarkMatter = value == true
            if config.AutoDarkMatterGalaxyFox or config.AutoClaimDarkMatter then
                context.SetDarkMatterStatus("Enabled. Reading DarkMatterQueue and server time...")
                spawn(function() context.StartMachine("DarkMatter") end)
            else
                context.StopMachine("DarkMatter")
                context.SetDarkMatterStatus("Disabled. No Dark Matter requests will be sent.")
            end
        end,
    })
    statusViews.DarkMatter = darkMatter:Paragraph({
        Title = "Dark Matter Status",
        Desc = "Disabled / create and claim routes resolve independently each session",
    })
    yieldUI("dark matter machine")

    local boost = UI.BoostsTab:Section({ Title = "Adaptive Boost Controller", Box = true, Opened = true })
    boost:Paragraph({
        Title = "RENEW FROM SAVE / REFILL WHEN EMPTY",
        Desc = "Uses Save boost timers and inventory; one mutation may be pending at a time.",
    })
    boost:Slider({
        Flag = "boost_renew_before",
        Title = "Renew Before Expiration",
        Desc = "Seconds remaining before an inventory boost is activated.",
        Step = 1,
        Value = { Min = 1, Max = 15, Default = 5 },
        Callback = function(value)
            config.BoostRenewBefore = math.clamp(math.floor(tonumber(value) or 5), 1, 15)
        end,
    })
    boost:Slider({
        Flag = "boost_purchase_lead",
        Title = "Buy Missing Potion Before Expiration",
        Desc = "When enabled stock is empty, opens the potion purchase window this many seconds before the active boost ends.",
        Step = 5,
        Value = { Min = 5, Max = 120, Default = 30 },
        Callback = function(value)
            config.BoostPurchaseLead =
                math.clamp(math.floor(tonumber(value) or 30), 5, 120)
        end,
    })
    for _, definition in ipairs({
        { "auto_triple_coins", "AutoTripleCoins", "Auto Triple Coins" },
        { "auto_triple_damage", "AutoTripleDamage", "Auto Triple Damage" },
        { "auto_super_lucky", "AutoSuperLucky", "Auto Super Lucky" },
        { "auto_ultra_lucky", "AutoUltraLucky", "Auto Ultra Lucky" },
    }) do
        local item = definition
        boost:Toggle({
            Flag = item[1],
            Title = item[3],
            Desc = "Renews inside the selected window; an empty stock may buy this exact potion.",
            Value = false,
            Callback = function(value)
                config[item[2]] = value == true
                context.ReconcileBoost()
            end,
        })
    end
    yieldUI("boost toggles")

    local potionShop = UI.BoostsTab:Section({ Title = "LowOnline Potion Shop", Box = true, Opened = true })
    potionShop:Toggle({
        Flag = "auto_buy_potions",
        Title = "Auto Buy Missing Potions",
        Desc = "Uses Purchase Boosts(name, false) only for enabled boosts with zero inventory stock.",
        Value = false,
        Callback = function(value)
            config.AutoBuyPotions = value == true
            context.ReconcileBoost()
        end,
    })
    potionShop:Button({
        Title = "CHECK BOOST ROUTES",
        Desc = "Resolves Activate Boost and Purchase Boosts locally without buying.",
        Icon = "refresh-cw",
        Callback = function()
            spawn(context.RefreshRoutes)
            if context.BoostEnabled() then spawn(context.StartBoost) end
        end,
    })
    statusViews.Boost = potionShop:Paragraph({
        Title = "Boost Automation Status",
        Desc = "Disabled / no boost activation or potion purchase is armed",
    })
    yieldUI("boost potion shop")

    return true, {
        AutoEggToggle = autoEggToggle,
        EggScopeDropdown = eggScope,
        EggDropdown = eggDropdown,
        EggPaceModeDropdown = eggPaceMode,
        EggManualDelaySlider = eggManualDelay,
        FuseModeToggles = fuseModeToggles,
        EnchantDropdown = enchantDropdown,
    }
end

return function(action, context)
    if action == "version" then return MODULE_VERSION end
    if action == "build" then return build(context) end
    return false, "unknown action"
end
