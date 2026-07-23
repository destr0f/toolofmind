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
for _, key in ipairs({ "EggCatalog", "Egg", "Routes", "Gold", "Rainbow", "DarkMatter", "Boost" }) do
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
    ReconcileBoost = noOp,
    BoostEnabled = function() return false end,
    StartBoost = noOp,
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

for key, setter in pairs(statusSetters) do
    assert(type(setter) == "function", key .. " setter was overwritten")
    setter("probe:" .. key)
    assert(statusViews[key].Desc == "probe:" .. key, key .. " status update failed")
end

print("PASS automation UI keeps status views and status setters separate")
