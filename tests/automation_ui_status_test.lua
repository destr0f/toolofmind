task = {
    spawn = function(callback)
        callback()
        return {}
    end,
}

local automationUI = require("../automation_ui_module")

local function newControl()
    return {
        Desc = "",
        SetDesc = function(self, value) self.Desc = tostring(value) end,
        Refresh = function() end,
        Select = function() end,
    }
end

local controlsByFlag = {}
local sectionMethods = {}
for _, methodName in ipairs({ "Paragraph", "Dropdown", "Button", "Toggle", "Slider" }) do
    sectionMethods[methodName] = function(_, definition)
        local control = newControl()
        control.Definition = definition
        if definition and definition.Flag then controlsByFlag[definition.Flag] = control end
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
for _, key in ipairs({
    "EggCatalog", "Egg", "Routes", "Gold", "Rainbow", "DarkMatter",
    "Fuse", "Enchant", "Boost",
}) do
    statusSetters[key] = function(value)
        local view = statusViews[key]
        assert(type(view) == "table", key .. " view was not installed")
        view:SetDesc(value)
    end
end

local noOp = function() end
local uiYieldCount = 0
local machineStarts = {}
local machineStops = {}
local accepted, controls = automationUI("build", {
    UI = {
        EggTab = newTab(),
        MonitorTab = newTab(),
        MachinesTab = newTab(),
        BoostsTab = newTab(),
    },
    Task = task,
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
    StartMachine = function(name) machineStarts[#machineStarts + 1] = name end,
    StopMachine = function(name) machineStops[#machineStops + 1] = name end,
    SetGoldStatus = statusSetters.Gold,
    SetRainbowStatus = statusSetters.Rainbow,
    SetDarkMatterStatus = statusSetters.DarkMatter,
    SetFuseStatus = statusSetters.Fuse,
    GetEnchantCatalog = function()
        return { "Coins V", "Fantasy Coins V", "Super Teamwork" }
    end,
    SetEnchantStatus = statusSetters.Enchant,
    ReconcileBoost = noOp,
    BoostEnabled = function() return false end,
    StartBoost = noOp,
    YieldUI = function() uiYieldCount = uiYieldCount + 1 end,
})

assert(accepted == true, tostring(controls))
assert(type(controls) == "table", "automation controls were not returned")
assert(uiYieldCount >= 8, "automation UI was not split into enough frame-sized stages")
assert(automationUI("version") == "1.6.4-lowonline")

local countSlider = controlsByFlag.dark_matter_batch_size
local timeSlider = controlsByFlag.dark_matter_max_wait_hours
assert(type(countSlider) == "table", "Dark Matter pet-count slider is missing")
assert(type(timeSlider) == "table", "Dark Matter time slider is missing")
countSlider.Definition.Callback(4)
timeSlider.Definition.Callback(12.5)
assert(config.DarkMatterBatchSize == 4, "Dark Matter pet-count slider did not update config")
assert(config.DarkMatterMaxWaitHours == 12.5, "Dark Matter time slider did not update config")

local paceMode = controlsByFlag.egg_pace_mode
local manualDelay = controlsByFlag.egg_manual_delay_ms
assert(type(paceMode) == "table", "AutoEgg pace dropdown is missing")
assert(type(manualDelay) == "table", "AutoEgg manual-delay slider is missing")
paceMode.Definition.Callback("Manual Delay")
manualDelay.Definition.Callback(75)
assert(config.EggPaceMode == "Manual Delay", "AutoEgg pace mode did not update config")
assert(config.EggManualDelayMs == 75, "AutoEgg manual delay did not update config")

local pandaFuse = controlsByFlag.lowonline_fuse_panda
local axolotlFuse = controlsByFlag.lowonline_fuse_axolotl
local tigerFuse = controlsByFlag.lowonline_fuse_tiger
local rareFuse = controlsByFlag.lowonline_fuse_rare
local epicFuse = controlsByFlag.lowonline_fuse_epic
assert(type(pandaFuse) == "table", "LowOnline Panda fuse toggle is missing")
assert(type(axolotlFuse) == "table", "LowOnline Axolotl fuse toggle is missing")
assert(type(tigerFuse) == "table", "LowOnline Tiger fuse toggle is missing")
assert(type(rareFuse) == "table", "LowOnline Rare fuse toggle is missing")
assert(type(epicFuse) == "table", "LowOnline Epic fuse toggle is missing")
pandaFuse.Definition.Callback(true)
axolotlFuse.Definition.Callback(true)
tigerFuse.Definition.Callback(true)
rareFuse.Definition.Callback(true)
epicFuse.Definition.Callback(true)
assert(config.AutoFusePanda and config.AutoFuseAxolotl and config.AutoFuseTiger
    and config.AutoFuseRare and config.AutoFuseEpic,
    "all five LowOnline fuse modes cannot stay enabled together")
assert(config.AutoFuse == true, "combined Fuse worker was not armed")
assert(#machineStarts == 5 and machineStarts[1] == "Fuse",
    "Fuse worker was not reconciled after each mode change")
rareFuse.Definition.Callback(false)
assert(config.AutoFusePanda and config.AutoFuseAxolotl and config.AutoFuseTiger
    and not config.AutoFuseRare and config.AutoFuseEpic,
    "disabling one Fuse mode disabled the other active modes")

local purchaseLead = controlsByFlag.boost_purchase_lead
local autoBuyPotions = controlsByFlag.auto_buy_potions
assert(type(purchaseLead) == "table", "potion purchase-lead slider is missing")
assert(type(autoBuyPotions) == "table", "auto-buy potion toggle is missing")
purchaseLead.Definition.Callback(45)
autoBuyPotions.Definition.Callback(true)
assert(config.BoostPurchaseLead == 45, "potion purchase lead did not update config")
assert(config.AutoBuyPotions == true, "auto-buy potions did not update config")

local enchantDropdown = controlsByFlag.equipped_enchant_targets
local autoEnchant = controlsByFlag.auto_enchant_equipped
assert(type(enchantDropdown) == "table", "equipped enchant multi-dropdown is missing")
assert(type(autoEnchant) == "table", "equipped auto-enchant toggle is missing")
enchantDropdown.Definition.Callback({ "Fantasy Coins V", "Super Teamwork" })
assert(type(config.EnchantTargets) == "table" and #config.EnchantTargets == 2,
    "multiple accepted enchant targets were not retained")
autoEnchant.Definition.Callback(true)
assert(config.AutoEnchantEquipped == true, "auto enchant did not update config")
assert(machineStarts[#machineStarts] == "Enchant", "Enchant worker was not started")
autoEnchant.Definition.Callback(false)
assert(machineStops[#machineStops] == "Enchant", "Enchant worker was not stopped")

for key, setter in pairs(statusSetters) do
    assert(type(setter) == "function", key .. " setter was overwritten")
    setter("probe:" .. key)
    assert(statusViews[key].Desc == "probe:" .. key, key .. " status update failed")
end

print("PASS automation UI keeps status views and status setters separate")
