local automationUI = require("../automation_ui_module")

local function newControl()
    return {
        Desc = "",
        SetDesc = function(self, value) self.Desc = tostring(value) end,
        Refresh = function() end,
        Select = function() end,
    }
end

local sectionMethods = {}
for _, methodName in ipairs({ "Paragraph", "Dropdown", "Button", "Toggle", "Slider" }) do
    sectionMethods[methodName] = function(_, definition)
        local control = newControl()
        control.Definition = definition
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
for _, key in ipairs({ "EggCatalog", "Egg", "Routes", "Gold", "Rainbow", "DarkMatter", "Boost" }) do
    statusSetters[key] = function(value)
        local view = statusViews[key]
        assert(type(view) == "table", key .. " view was not installed")
        view:SetDesc(value)
    end
end

local noOp = function() end
local accepted, controls = automationUI("build", {
    UI = {
        EggTab = newTab(),
        MonitorTab = newTab(),
        MachinesTab = newTab(),
        BoostsTab = newTab(),
    },
    Config = {},
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
})

assert(accepted == true, tostring(controls))
assert(type(controls) == "table", "automation controls were not returned")

for key, setter in pairs(statusSetters) do
    assert(type(setter) == "function", key .. " setter was overwritten")
    setter("probe:" .. key)
    assert(statusViews[key].Desc == "probe:" .. key, key .. " status update failed")
end

print("PASS automation UI keeps status views and status setters separate")
