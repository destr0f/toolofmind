-- Lazy UI extension for PSX OG Nova develop.
-- Keeps optional automation controls outside the main executor chunk.

local MODULE_VERSION = "1.2.0"

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
        "ReconcileBoost", "BoostEnabled", "StartBoost",
    })
    if not valid then return false, problem end

    local UI = context.UI
    local config = context.Config
    local statusViews = context.StatusViews
    local yieldUI = type(context.YieldUI) == "function" and context.YieldUI or function() end

    local eggCatalog = UI.EggTab:Section({ Title = "01 / Live Egg Catalog", Box = true, Opened = true })
    eggCatalog:Paragraph({
        Title = "LOCAL DISCOVERY / ZERO PROBES",
        Desc = "Reads Library.Directory.Eggs and the current __MAP without purchasing.",
    })
    local eggScope = eggCatalog:Dropdown({
        Flag = "egg_catalog_scope",
        Title = "Catalog Scope",
        Desc = "Nearby uses the 15-stud interaction radius; All lists every hatchable ID.",
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
            task.spawn(function()
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
    local autoEggToggle = eggAutomation:Toggle({
        Flag = "auto_egg",
        Title = "Enable Auto Hatch",
        Desc = "Requires the selected physical egg within 15 studs; failed preflight sends nothing.",
        Value = false,
        Callback = function(value)
            local enabled = value == true
            if config.AutoEgg == enabled then return end
            config.AutoEgg = enabled
            if enabled then
                task.spawn(context.StartAutoEgg)
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
        Callback = function() task.spawn(context.RefreshRoutes) end,
    })
    statusViews.Routes = routes:Paragraph({
        Title = "Command Status",
        Desc = "Manual diagnostics are idle. Press Refresh when needed.",
    })
    yieldUI("route diagnostics")

    local machines = UI.MachinesTab:Section({ Title = "Safe Conversion Pipeline", Box = true, Opened = true })
    machines:Paragraph({
        Title = "NORMAL > GOLD > RAINBOW > DARK MATTER",
        Desc = "Galaxy Fox and live event pets; every batch is validated and confirmed from Save.",
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
        Title = "REFRESH EVENT PET CATALOG",
        Desc = "Re-reads Directory.Eggs/Pets locally; no machine request.",
        Icon = "refresh-cw",
        Callback = function()
            task.spawn(function()
                local _, _, summary = context.GetMachinePetCatalog(true)
                context.SetRouteStatus("Pet catalog refreshed locally: " .. tostring(summary))
            end)
        end,
    })
    yieldUI("machine controls")

    local gold = UI.MachinesTab:Section({ Title = "Golden Machine / Stage 1", Box = true, Opened = true })
    gold:Toggle({
        Flag = "auto_golden_galaxy_fox",
        Title = "Auto Golden Target Pets",
        Desc = "Normal targets; protects equipped and locked pets; enchants are not filtered.",
        Value = false,
        Callback = function(value)
            config.AutoGoldenGalaxyFox = value == true
            if config.AutoGoldenGalaxyFox then
                context.SetGoldStatus("Enabled. Loading the protected worker in the serial lane...")
                task.spawn(function() context.StartMachine("Gold") end)
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
        Title = "Auto Rainbow Target Pets",
        Desc = "Golden targets; protects equipped and locked pets; enchants are not filtered.",
        Value = false,
        Callback = function(value)
            config.AutoRainbowGalaxyFox = value == true
            if config.AutoRainbowGalaxyFox then
                context.SetRainbowStatus("Enabled. Loading the protected worker in the serial lane...")
                task.spawn(function() context.StartMachine("Rainbow") end)
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
        Desc = "Rainbow targets; protects Tech Coins IV-V, equipped and locked pets.",
        Value = false,
        Callback = function(value)
            config.AutoDarkMatterGalaxyFox = value == true
            if config.AutoDarkMatterGalaxyFox or config.AutoClaimDarkMatter then
                context.SetDarkMatterStatus("Enabled. Loading the Dark Matter worker in the serial lane...")
                task.spawn(function() context.StartMachine("DarkMatter") end)
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
                task.spawn(function() context.StartMachine("DarkMatter") end)
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
            Desc = "Renews inside the selected window; an empty stock may request one bundle.",
            Value = false,
            Callback = function(value)
                config[item[2]] = value == true
                context.ReconcileBoost()
            end,
        })
    end
    yieldUI("boost toggles")

    local bundle = UI.BoostsTab:Section({ Title = "Boost Bundle Fallback", Box = true, Opened = true })
    bundle:Toggle({
        Flag = "auto_boost_bundle",
        Title = "Auto Buy Boost Bundle",
        Desc = "Costs 270k Diamonds and buys only when an enabled boost has zero stock.",
        Value = false,
        Callback = function(value)
            config.AutoBoostBundle = value == true
            context.ReconcileBoost()
        end,
    })
    bundle:Button({
        Title = "CHECK BOOST ROUTES",
        Desc = "Resolves boost routes locally without spending Diamonds.",
        Icon = "refresh-cw",
        Callback = function()
            task.spawn(context.RefreshRoutes)
            if context.BoostEnabled() then task.spawn(context.StartBoost) end
        end,
    })
    statusViews.Boost = bundle:Paragraph({
        Title = "Boost Automation Status",
        Desc = "Disabled / no boost or bundle request is armed",
    })
    yieldUI("boost bundle")

    return true, {
        AutoEggToggle = autoEggToggle,
        EggScopeDropdown = eggScope,
        EggDropdown = eggDropdown,
    }
end

return function(action, context)
    if action == "version" then return MODULE_VERSION end
    if action == "build" then return build(context) end
    return false, "unknown action"
end
