-- Lazy UI extension for PSX OG Nova develop.
-- Keeps optional automation controls outside the main executor chunk.

local MODULE_VERSION = "1.5.2"

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
        "GetEnchantOptions", "StartEnchant", "StopEnchant", "RestartEnchant", "SetEnchantStatus",
        "ReconcileBoost", "BoostEnabled", "StartBoost",
        "GetRuleEnchantCatalog", "GetRuleFormula", "RulesChanged",
        "ExportRuleProfiles", "ImportRuleProfiles",
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
        Flag = "egg_delay_mode",
        Title = "Purchase Timing",
        Desc = "Adaptive learns from clean server acknowledgements; Manual waits after completion.",
        Values = { "Adaptive", "Manual" },
        Value = config.EggDelayMode == "Manual" and "Manual" or "Adaptive",
        Multi = false,
        AllowNone = false,
        Callback = function(value)
            config.EggDelayMode = value == "Manual" and "Manual" or "Adaptive"
        end,
    })
    eggAutomation:Slider({
        Flag = "egg_manual_delay",
        Title = "Manual Purchase Delay",
        Desc = "0.00-10.00 seconds after the previous hatch fully completes.",
        Step = 0.05,
        Value = { Min = 0, Max = 10, Default = tonumber(config.EggManualDelay) or 0 },
        Callback = function(value)
            config.EggManualDelay = math.clamp(tonumber(value) or 0, 0, 10)
        end,
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
        Desc = "Requires the selected egg within 15 studs; 12 bounded attempts span a 10-minute recovery window without overlapping purchases.",
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
        Desc = "Pixel Demon only; its live Directory.Pets ID is resolved per session and every batch is revalidated from Save.",
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
        Title = "VERIFY PIXEL DEMON CATALOG",
        Desc = "Resolves the exact Pixel Demon species from live Directory.Pets; no machine request.",
        Icon = "refresh-cw",
        Callback = function()
            task.spawn(function()
                local _, _, summary = context.GetMachinePetCatalog(true)
                context.SetRouteStatus("Pet catalog refreshed locally: " .. tostring(summary))
            end)
        end,
    })
    yieldUI("machine controls")

    local ruleBuilder = UI.MachinesTab:Section({ Title = "Simple Enchant Protection", Box = true, Opened = true })
    ruleBuilder:Paragraph({
        Title = "ONE VARIATION = UP TO 3 REQUIRED ENCHANTS",
        Desc = "Example: Royalty + Rainbow Coins V + Super Teamwork. A pet is protected when it matches any enabled variation.",
    })
    local selectedProfile, selectedRule = "Gold", 0
    local copySourceProfile = "Gold"
    local profiles = { "Gold", "Rainbow", "DarkMatter", "DMDelete" }
    local profileChoices = { "Gold Machine", "Rainbow Machine", "Dark Matter Machine", "Dark Matter Auto Delete" }
    local profileKeys = {
        ["Gold Machine"] = "Gold", ["Rainbow Machine"] = "Rainbow",
        ["Dark Matter Machine"] = "DarkMatter", ["Dark Matter Auto Delete"] = "DMDelete",
    }
    local profileTitles = {
        Gold = "Gold Machine", Rainbow = "Rainbow Machine",
        DarkMatter = "Dark Matter Machine", DMDelete = "Dark Matter Auto Delete",
    }
    local emptySlot = "-- Empty --"
    local romanLevels = { I = 1, II = 2, III = 3, IV = 4, V = 5 }
    local levelRomans = { "I", "II", "III", "IV", "V" }
    local levelled = {
        ["agility"] = true, ["chest breaker"] = true, ["coins"] = true,
        ["diamonds"] = true, ["fantasy coins"] = true, ["rainbow coins"] = true,
        ["strength"] = true, ["tech coins"] = true,
    }
    local rulePicker, enchantSelector, listView, formulaView
    local draftSelections = {}
    local function trim(value)
        return string.match(tostring(value or ""), "^%s*(.-)%s*$") or ""
    end
    local function profile()
        config.EnchantRuleProfiles = type(config.EnchantRuleProfiles) == "table"
            and config.EnchantRuleProfiles or {}
        local value = config.EnchantRuleProfiles[selectedProfile]
        if type(value) ~= "table" then
            value = { Enabled = true, Revision = 1, Rules = {} }
            config.EnchantRuleProfiles[selectedProfile] = value
        end
        value.Rules = type(value.Rules) == "table" and value.Rules or {}
        return value
    end
    local function conditionLabel(condition)
        if type(condition) ~= "table" then return "?" end
        local name = trim(condition.Enchant)
        local level = math.clamp(math.floor(tonumber(condition.Level) or 1), 1, 5)
        if condition.Mode == "Exact" then return name .. " " .. levelRomans[level] end
        if condition.Mode == "IV/V" then return name .. " IV/V" end
        if condition.Mode == "AtLeast" then
            return name .. " " .. levelRomans[level] .. (level < 5 and "+" or "")
        end
        return name
    end
    local function ruleLabel(index, rule)
        local conditions = {}
        for _, condition in ipairs(type(rule) == "table" and type(rule.Conditions) == "table"
            and rule.Conditions or {}) do
            conditions[#conditions + 1] = conditionLabel(condition)
        end
        local text = #conditions > 0 and table.concat(conditions, " + ") or "empty"
        return string.format("Variation %d [%s] %s", index,
            type(rule) == "table" and rule.Enabled == false and "OFF" or "ON", text)
    end
    local function pickerValues()
        local values = { "+ New variation" }
        for index, rule in ipairs(profile().Rules) do
            values[#values + 1] = ruleLabel(index, rule)
        end
        return values
    end
    local function parseRuleIndex(label)
        return tonumber(string.match(tostring(label or ""), "^Variation (%d+)")) or 0
    end
    local function enchantChoices()
        local values, seen = {}, {}
        local function add(value)
            local key = string.lower(trim(value))
            if key ~= "" and not seen[key] then
                seen[key] = true
                values[#values + 1] = value
            end
        end
        for _, rawName in ipairs(context.GetRuleEnchantCatalog()) do
            local name = trim(rawName)
            add(name)
            if levelled[string.lower(name)] then
                for _, roman in ipairs(levelRomans) do add(name .. " " .. roman) end
                add(name .. " IV/V")
                for _, roman in ipairs(levelRomans) do add(name .. " " .. roman .. "+") end
            end
        end
        return values
    end
    local function choiceCondition(choice)
        choice = trim(choice)
        if choice == "" or choice == emptySlot then return nil end
        local unionName = string.match(choice, "^(.-) IV/V$")
        if unionName then return { Enchant = trim(unionName), Mode = "IV/V", Level = 4 } end
        local minimumName, minimumRoman = string.match(choice, "^(.-) ([IV]+)%+$")
        local minimumLevel = minimumRoman and romanLevels[minimumRoman]
        if minimumName and minimumLevel then
            return { Enchant = trim(minimumName), Mode = "AtLeast", Level = minimumLevel }
        end
        local name, roman = string.match(choice, "^(.-) ([IV]+)$")
        local level = roman and romanLevels[roman]
        if name and level then return { Enchant = trim(name), Mode = "Exact", Level = level } end
        return { Enchant = choice, Mode = "Any", Level = 1 }
    end
    local function draftRule()
        local conditions, seen = {}, {}
        for index = 1, math.min(#draftSelections, 3) do
            local condition = choiceCondition(draftSelections[index])
            if condition then
                local key = string.lower(condition.Enchant) .. ":" .. condition.Mode .. ":" .. tostring(condition.Level)
                if not seen[key] then
                    seen[key] = true
                    conditions[#conditions + 1] = condition
                end
            end
        end
        if #conditions == 0 then return nil end
        return { Enabled = true, Conditions = conditions }
    end
    local function loadDraft()
        draftSelections = {}
        local rule = profile().Rules[selectedRule]
        if type(rule) == "table" then
            for index, condition in ipairs(type(rule.Conditions) == "table" and rule.Conditions or {}) do
                if index > 3 then break end
                draftSelections[index] = conditionLabel(condition)
            end
        end
        if enchantSelector then
            pcall(function()
                enchantSelector.Value = draftSelections
                if type(enchantSelector.Display) == "function" then enchantSelector:Display() end
            end)
        end
    end
    local function refreshSummary()
        local value = profile()
        local lines = {
            string.format("Profile: %s | %s | Dry Run: %s", profileTitles[selectedProfile] or selectedProfile,
                value.Enabled == false and "DISABLED" or "ENABLED", value.DryRun == true and "ON" or "OFF"),
        }
        if #value.Rules == 0 then
            lines[#lines + 1] = "No variations configured."
        else
            for index, rule in ipairs(value.Rules) do lines[#lines + 1] = ruleLabel(index, rule) end
        end
        if listView then pcall(function() listView:SetDesc(table.concat(lines, "\n")) end) end
        if formulaView then pcall(function() formulaView:SetDesc(context.GetRuleFormula(selectedProfile)) end) end
    end
    local function refreshEditor(resetSelection)
        local rules = profile().Rules
        if resetSelection or selectedRule > #rules then selectedRule = 0 end
        if rulePicker then
            local values = pickerValues()
            pcall(function()
                rulePicker:Refresh(values)
                rulePicker.Value = selectedRule > 0 and values[selectedRule + 1] or values[1]
                if type(rulePicker.Display) == "function" then rulePicker:Display() end
            end)
        end
        loadDraft()
        refreshSummary()
    end
    local function changed(reason)
        local value = profile()
        value.Revision = (tonumber(value.Revision) or 0) + 1
        context.RulesChanged(selectedProfile, reason)
        refreshEditor(false)
    end
    ruleBuilder:Dropdown({
        Flag = "rule_profile",
        Title = "Where These Rules Apply",
        Desc = "Each machine and DM auto-delete keeps its own independent list.",
        Values = profileChoices,
        Value = profileTitles[selectedProfile],
        Multi = false,
        AllowNone = false,
        Callback = function(value)
            selectedProfile = profileKeys[value] or "Gold"
            selectedRule = 0
            refreshEditor(true)
        end,
    })
    listView = ruleBuilder:Paragraph({
        Title = "Configured Variations",
        Desc = "Loading profile...",
    })
    rulePicker = ruleBuilder:Dropdown({
        Flag = "rule_variation",
        Title = "Variation To Edit",
        Desc = "The full enchant combination is shown here; no numeric indices.",
        Values = pickerValues(),
        Value = "+ New variation",
        Multi = false,
        AllowNone = false,
        Callback = function(value)
            selectedRule = parseRuleIndex(value)
            loadDraft()
            refreshSummary()
        end,
    })
    local choices = enchantChoices()
    enchantSelector = ruleBuilder:Dropdown({
        Flag = "rule_enchant_selection",
        Title = "Required Enchants (Choose Up To 3)",
        Desc = "Selected enchants use AND. Add another variation when you need an OR option.",
        Values = choices,
        Value = {},
        Multi = true,
        AllowNone = true,
        SearchBarEnabled = true,
        Callback = function(values)
            local selected = {}
            for _, value in ipairs(type(values) == "table" and values or {}) do
                if tostring(value) ~= emptySlot and #selected < 3 then selected[#selected + 1] = tostring(value) end
            end
            draftSelections = selected
            if type(values) == "table" and #values > 3 and enchantSelector then
                enchantSelector.Value = selected
                if type(enchantSelector.Display) == "function" then enchantSelector:Display() end
                context.SetRouteStatus("A variation can contain no more than 3 required enchants.")
            end
        end,
    })
    ruleBuilder:Button({
        Title = "ADD AS NEW VARIATION",
        Desc = "Adds these 1-3 enchants as another OR option.",
        Icon = "plus",
        Callback = function()
            local value, rule = profile(), draftRule()
            if not rule then context.SetRouteStatus("Choose at least one enchant first."); return end
            if #value.Rules >= 8 then context.SetRouteStatus("Maximum 8 variations per profile."); return end
            value.Rules[#value.Rules + 1] = rule
            selectedRule = #value.Rules
            changed("add variation")
        end,
    })
    ruleBuilder:Button({
        Title = "SAVE SELECTED VARIATION",
        Desc = "Replaces the selected variation with the three slots above.",
        Icon = "save",
        Callback = function()
            local value, replacement = profile(), draftRule()
            if not replacement then context.SetRouteStatus("Choose at least one enchant first."); return end
            local current = value.Rules[selectedRule]
            if type(current) ~= "table" then context.SetRouteStatus("Select an existing variation or add a new one."); return end
            replacement.Enabled = current.Enabled ~= false
            value.Rules[selectedRule] = replacement
            changed("save variation")
        end,
    })
    ruleBuilder:Button({
        Title = "ENABLE / DISABLE SELECTED VARIATION",
        Desc = "Temporarily ignores this variation without deleting it.",
        Icon = "circle-power",
        Callback = function()
            local rule = profile().Rules[selectedRule]
            if type(rule) ~= "table" then context.SetRouteStatus("Select a variation first."); return end
            rule.Enabled = rule.Enabled == false
            changed(rule.Enabled == false and "disable variation" or "enable variation")
        end,
    })
    ruleBuilder:Button({
        Title = "DELETE SELECTED VARIATION",
        Desc = "Deletes only the visibly selected variation.",
        Icon = "trash-2",
        Callback = function()
            local value = profile()
            if type(value.Rules[selectedRule]) ~= "table" then context.SetRouteStatus("Select a variation first."); return end
            table.remove(value.Rules, selectedRule)
            selectedRule = 0
            changed("delete variation")
        end,
    })
    ruleBuilder:Button({
        Title = "CLEAR ENCHANT SLOTS",
        Desc = "Clears only the editor; saved variations stay unchanged.",
        Icon = "eraser",
        Callback = function()
            selectedRule = 0
            loadDraft()
            refreshSummary()
        end,
    })
    ruleBuilder:Button({
        Title = "ENABLE / DISABLE WHOLE PROFILE",
        Desc = "Machine profile off means no enchant protection. DMDelete off deletes nothing.",
        Icon = "power",
        Callback = function()
            local value = profile(); value.Enabled = value.Enabled == false
            changed(value.Enabled == false and "disable profile" or "enable profile")
        end,
    })
    ruleBuilder:Button({
        Title = "TOGGLE PROFILE DRY RUN",
        Desc = "Previews decisions without sending a craft/delete request.",
        Icon = "flask-conical",
        Callback = function()
            local value = profile(); value.DryRun = value.DryRun ~= true
            changed(value.DryRun and "enable profile dry run" or "disable profile dry run")
        end,
    })
    ruleBuilder:Dropdown({
        Flag = "rule_copy_source",
        Title = "Copy Rules From",
        Desc = "Select a source profile, then copy it over the active profile.",
        Values = profileChoices,
        Value = profileTitles[copySourceProfile],
        Multi = false,
        AllowNone = false,
        Callback = function(value)
            copySourceProfile = profileKeys[value] or "Gold"
        end,
    })
    ruleBuilder:Button({
        Title = "COPY SOURCE TO ACTIVE PROFILE",
        Desc = "Deep-copies rules, enabled state and Dry Run; revisions remain independent.",
        Icon = "copy-check",
        Callback = function()
            if copySourceProfile == selectedProfile then return end
            local source = config.EnchantRuleProfiles and config.EnchantRuleProfiles[copySourceProfile]
            if type(source) ~= "table" then return end
            local copy = { Enabled = source.Enabled ~= false, DryRun = source.DryRun == true, Revision = 1, Rules = {} }
            for _, sourceRule in ipairs(type(source.Rules) == "table" and source.Rules or {}) do
                if #copy.Rules >= 8 then break end
                local targetRule = { Enabled = sourceRule.Enabled ~= false, Conditions = {} }
                for _, item in ipairs(type(sourceRule.Conditions) == "table" and sourceRule.Conditions or {}) do
                    if #targetRule.Conditions >= 8 then break end
                    targetRule.Conditions[#targetRule.Conditions + 1] = {
                        Enchant = item.Enchant, Mode = item.Mode, Level = item.Level,
                    }
                end
                copy.Rules[#copy.Rules + 1] = targetRule
            end
            config.EnchantRuleProfiles[selectedProfile] = copy
            selectedRule = 0
            changed("copy profile")
        end,
    })
    local ruleJsonText = ""
    local ruleJsonInput = ruleBuilder:Input({
        Flag = "rule_profile_json",
        Title = "Rules JSON",
        Desc = "Export all four profiles or paste a previously exported JSON document and import it.",
        Type = "Textarea",
        Placeholder = "{\"Gold\":{...}}",
        Value = "",
        Callback = function(value) ruleJsonText = tostring(value or "") end,
    })
    ruleBuilder:Button({
        Title = "EXPORT RULES JSON",
        Desc = "Writes bounded profile JSON into this field and the clipboard when available.",
        Icon = "download",
        Callback = function()
            local ok, value = context.ExportRuleProfiles()
            if not ok then context.SetRouteStatus("Rule export failed: " .. tostring(value)); return end
            ruleJsonText = tostring(value)
            pcall(function() ruleJsonInput:Set(ruleJsonText) end)
            if type(setclipboard) == "function" then pcall(setclipboard, ruleJsonText) end
            context.SetRouteStatus("Enchant rules exported locally; no server request was sent.")
        end,
    })
    ruleBuilder:Button({
        Title = "IMPORT RULES JSON",
        Desc = "Validates the bounded schema before replacing profiles. Invalid or incomplete JSON is rejected.",
        Icon = "upload",
        Callback = function()
            local ok, value = context.ImportRuleProfiles(ruleJsonText)
            if not ok then context.SetRouteStatus("Rule import rejected: " .. tostring(value)); return end
            selectedRule = 0
            changed("import profiles")
            context.SetRouteStatus("Enchant rules imported locally; no server request was sent.")
        end,
    })
    formulaView = ruleBuilder:Paragraph({
        Title = "Matcher Formula (Advanced)",
        Desc = context.GetRuleFormula(selectedProfile),
    })
    refreshEditor(true)
    yieldUI("enchant rule builder")

    local gold = UI.MachinesTab:Section({ Title = "Golden Machine / Stage 1", Box = true, Opened = true })
    gold:Toggle({
        Flag = "auto_golden_galaxy_fox",
        Title = "Auto Golden Pixel Demon",
        Desc = "Crafts unprotected normal Pixel Demon. Uses the independent Gold Machine variation list above.",
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
        Title = "Auto Rainbow Pixel Demon",
        Desc = "Crafts unprotected golden Pixel Demon. Uses the independent Rainbow Machine variation list above.",
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
        Title = "Auto Dark Matter Pixel Demon",
        Desc = "Only rainbow Pixel Demon; protects Rainbow Coins V, equipped and locked pets.",
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
    darkMatter:Dropdown({
        Flag = "dm_cleanup_scope",
        Title = "DM Cleanup Scope",
        Desc = "Newly Claimed only is the safe default; All DM also examines older matching Dark Matter pets.",
        Values = { "Newly Claimed", "All Dark Matter Pets" },
        Value = config.DMCleanupScope == "All Dark Matter Pets" and "All Dark Matter Pets" or "Newly Claimed",
        Multi = false,
        AllowNone = false,
        Callback = function(value)
            config.DMCleanupScope = value == "All Dark Matter Pets" and "All Dark Matter Pets" or "Newly Claimed"
            config.DMCleanupConfirmed = false
        end,
    })
    darkMatter:Slider({
        Flag = "dm_cleanup_batch",
        Title = "DM Delete Batch",
        Desc = "Bounded destructive batch size.",
        Step = 1,
        Value = { Min = 20, Max = 30, Default = tonumber(config.DMCleanupBatchSize) or 25 },
        Callback = function(value) config.DMCleanupBatchSize = math.clamp(math.floor(tonumber(value) or 25), 20, 30) end,
    })
    darkMatter:Toggle({
        Flag = "dm_cleanup_dry_run",
        Title = "DM Cleanup Dry Run",
        Desc = "Enabled by default. Plans DELETE/KEEP decisions without invoking Delete Several Pets.",
        Value = true,
        Callback = function(value) config.DMCleanupDryRun = value ~= false end,
    })
    darkMatter:Toggle({
        Flag = "dm_cleanup_confirmed",
        Title = "Confirm Destructive DM Cleanup",
        Desc = "Required in addition to Enable; changing scope clears this confirmation.",
        Value = false,
        Callback = function(value) config.DMCleanupConfirmed = value == true end,
    })
    darkMatter:Toggle({
        Flag = "dm_cleanup_enabled",
        Title = "Enable Destructive DM Cleanup",
        Desc = "Empty protection rules, Dry Run, missing confirmation, equipped, locked or incomplete data always block deletion.",
        Value = false,
        Callback = function(value)
            config.DMCleanupEnabled = value == true
            if config.AutoDarkMatterGalaxyFox or config.AutoClaimDarkMatter or config.DMCleanupEnabled then
                task.spawn(function() context.StartMachine("DarkMatter") end)
            else
                context.StopMachine("DarkMatter")
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

    local enchant = UI.MachinesTab:Section({ Title = "Fast Equipped-Pet Enchant", Box = true, Opened = true })
    enchant:Paragraph({
        Title = "ONE PET > ONE ROLL > SAVE ACK",
        Desc = "Keeps one equipped UID locked until it receives any selected enchant, then advances immediately.",
    })
    local enchantTargets = enchant:Dropdown({
        Flag = "auto_enchant_targets",
        Title = "Target Enchants",
        Desc = "Select one or more acceptable results. Exact live Directory.Powers tier names are used.",
        Values = context.GetEnchantOptions(),
        Value = type(config.EnchantTargets) == "table" and config.EnchantTargets or {},
        Multi = true,
        AllowNone = true,
        SearchBarEnabled = true,
        Callback = function(value)
            local selected, seen = {}, {}
            if type(value) == "table" then
                for key, item in pairs(value) do
                    local raw = type(key) == "string" and item == true and key or item
                    if type(raw) == "string" and raw ~= "" and not seen[raw] then
                        seen[raw] = true
                        selected[#selected + 1] = raw
                    end
                end
            elseif type(value) == "string" and value ~= "" then
                selected[1] = value
            end
            table.sort(selected)
            config.EnchantTargets = selected
            if config.AutoEnchant then context.RestartEnchant() end
        end,
    })
    local autoEnchantToggle = enchant:Toggle({
        Flag = "auto_enchant_equipped",
        Title = "Auto Enchant Equipped Pets",
        Desc = "One Enchant Pet request may exist at a time; no fixed remote index and no animation wait.",
        Value = false,
        Callback = function(value)
            config.AutoEnchant = value == true
            if config.AutoEnchant then
                context.SetEnchantStatus("Enabled. Locking one eligible equipped pet until any selected enchant appears...")
                task.spawn(context.StartEnchant)
            else
                context.StopEnchant("Disabled. No enchant request is active.")
            end
        end,
    })
    statusViews.Enchant = enchant:Paragraph({
        Title = "Auto Enchant Status",
        Desc = "Disabled / select target enchants before enabling",
    })
    yieldUI("auto enchant")

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
        EnchantTargetsDropdown = enchantTargets,
        AutoEnchantToggle = autoEnchantToggle,
    }
end

return function(action, context)
    if action == "version" then return MODULE_VERSION end
    if action == "build" then return build(context) end
    return false, "unknown action"
end
