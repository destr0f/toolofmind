local automationUI = require("../automation_ui_module")

local function newControl()
    return {
        Desc = "",
        SetDesc = function(self, value) self.Desc = tostring(value) end,
        Set = function(self, value) self.Value = tostring(value) end,
        Refresh = function() end,
        Select = function() end,
    }
end

local controlsByFlag = {}
local controlsByTitle = {}
local sectionMethods = {}
for _, methodName in ipairs({ "Paragraph", "Dropdown", "Button", "Toggle", "Slider", "Input" }) do
    sectionMethods[methodName] = function(_, definition)
        local control = newControl()
        control.Definition = definition
        if definition and definition.Flag then controlsByFlag[definition.Flag] = control end
        if definition and definition.Title then controlsByTitle[definition.Title] = control end
        return control
    end
end

local function newTab()
    return {
        Section = function(_, definition)
            return setmetatable({ Definition = definition }, { __index = sectionMethods })
        end,
    }
end

local statusViews = {}
local statusSetters = {}
local config = {}
for _, key in ipairs({ "EggCatalog", "Egg", "Routes", "Gold", "Rainbow", "DarkMatter", "Enchant", "Boost" }) do
    statusSetters[key] = function(value)
        local view = statusViews[key]
        assert(type(view) == "table", key .. " view was not installed")
        view:SetDesc(value)
    end
end

local noOp = function() end
local uiYieldCount = 0
local accepted, controls = automationUI("build", {
    UI = {
        EggTab = newTab(),
        MonitorTab = newTab(),
        MachinesTab = newTab(),
        BoostsTab = newTab(),
    },
    Config = config,
    StatusViews = statusViews,
    RefreshEggs = noOp,
    EnsureAutoEgg = function() return true end,
    InvalidateEggCatalog = noOp,
    StartAutoEgg = noOp,
    StopAutoEgg = noOp,
    EggIdForLabel = noOp,
    SetEggCatalogStatus = statusSetters.EggCatalog,
    RefreshRoutes = noOp,
    SetRouteStatus = statusSetters.Routes,
    GetMachinePetCatalog = function() return {}, {}, "ok" end,
    StartMachine = noOp,
    StopMachine = noOp,
    SetGoldStatus = statusSetters.Gold,
    SetRainbowStatus = statusSetters.Rainbow,
    SetDarkMatterStatus = statusSetters.DarkMatter,
    GetEnchantOptions = function()
        return { "Royalty", "Tech Coins IV", "Tech Coins V" }
    end,
    StartEnchant = noOp,
    StopEnchant = noOp,
    RestartEnchant = noOp,
    SetEnchantStatus = statusSetters.Enchant,
    ReconcileBoost = noOp,
    BoostEnabled = function() return false end,
    StartBoost = noOp,
    GetRuleEnchantCatalog = function()
        return { "Rainbow Coins", "Royalty", "Charm" }
    end,
    GetRuleFormula = function() return "Has(Rainbow Coins AtLeast 5)" end,
    RulesChanged = noOp,
    ExportRuleProfiles = function() return true, "{}" end,
    ImportRuleProfiles = function() return true, "imported" end,
    YieldUI = function() uiYieldCount = uiYieldCount + 1 end,
})

assert(accepted == true, tostring(controls))
assert(type(controls) == "table", "automation controls were not returned")
assert(uiYieldCount >= 8, "automation UI was not split into enough frame-sized stages")

local countSlider = controlsByFlag.dark_matter_batch_size
local timeSlider = controlsByFlag.dark_matter_max_wait_hours
assert(type(countSlider) == "table", "Dark Matter pet-count slider is missing")
assert(type(timeSlider) == "table", "Dark Matter time slider is missing")
countSlider.Definition.Callback(4)
timeSlider.Definition.Callback(12.5)
assert(config.DarkMatterBatchSize == 4, "Dark Matter pet-count slider did not update config")
assert(config.DarkMatterMaxWaitHours == 12.5, "Dark Matter time slider did not update config")

local enchantTargets = controlsByFlag.auto_enchant_targets
local enchantToggle = controlsByFlag.auto_enchant_equipped
assert(type(enchantTargets) == "table", "multi-enchant target dropdown is missing")
assert(enchantTargets.Definition.Multi == true, "enchant dropdown is not multi-select")
assert(type(enchantToggle) == "table", "auto-enchant toggle is missing")
enchantTargets.Definition.Callback({ "Royalty", "Tech Coins V" })
assert(#config.EnchantTargets == 2, "multi-enchant targets were not stored")

assert(controlsByFlag.rule_index == nil, "legacy numeric rule index is still visible")
assert(controlsByFlag.rule_condition_index == nil, "legacy numeric condition index is still visible")
assert(type(controlsByFlag.rule_variation) == "table", "named variation selector is missing")
for index = 1, 3 do
    assert(type(controlsByFlag["rule_enchant_slot_" .. tostring(index)]) == "table",
        "simple enchant slot " .. tostring(index) .. " is missing")
end
controlsByFlag.rule_enchant_slot_1.Definition.Callback("Royalty")
controlsByFlag.rule_enchant_slot_2.Definition.Callback("Rainbow Coins V")
controlsByFlag.rule_enchant_slot_3.Definition.Callback("Super Teamwork")
controlsByTitle["ADD AS NEW VARIATION"].Definition.Callback()
local goldRules = config.EnchantRuleProfiles.Gold.Rules
assert(#goldRules == 1, "simple builder did not add one visible variation")
assert(#goldRules[1].Conditions == 3, "simple builder did not save all three enchant slots")
assert(goldRules[1].Conditions[1].Enchant == "Royalty" and goldRules[1].Conditions[1].Mode == "Any",
    "unlevelled enchant slot was not saved as Any")
assert(goldRules[1].Conditions[2].Enchant == "Rainbow Coins"
    and goldRules[1].Conditions[2].Mode == "Exact" and goldRules[1].Conditions[2].Level == 5,
    "Rainbow Coins V was not decoded into an exact tier condition")
assert(string.find(controlsByTitle["Configured Variations"].Desc, "Royalty + Rainbow Coins V + Super Teamwork", 1, true),
    "active variation list does not show the complete saved combination")

for key, setter in pairs(statusSetters) do
    assert(type(setter) == "function", key .. " setter was overwritten")
    setter("probe:" .. key)
    assert(statusViews[key].Desc == "probe:" .. key, key .. " status update failed")
end

print("PASS automation UI keeps status views and status setters separate")
