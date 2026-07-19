-- Minimal WindUI stability probe: no remotes, hooks or background loops.
local env = getgenv()

if type(env.PSX_OG_MENU_TEST_CLEANUP) == "function" then
    pcall(env.PSX_OG_MENU_TEST_CLEANUP)
end

local WindUI = loadstring(game:HttpGet(
    "https://github.com/Footagesus/WindUI/releases/download/1.6.64-fix/main.lua"
))()

local Window = WindUI:CreateWindow({
    Title = "PSX OG | Menu Test",
    Icon = "shield-check",
    Author = "No hooks • No loops • No remotes",
    Folder = "PSX_Menu_Test",
    Size = UDim2.fromOffset(620, 420),
    MinSize = Vector2.new(520, 360),
    MaxSize = Vector2.new(900, 650),
    ToggleKey = Enum.KeyCode.RightShift,
    Transparent = true,
    Resizable = true,
    SideBarWidth = 180,
    HideSearchBar = false,
    ScrollBarEnabled = true,
    Acrylic = false
})

local MainTab = Window:Tab({ Title = "Проверка", Icon = "activity" })
local Section = MainTab:Section({ Title = "Чистый тест WindUI", Box = true, Opened = true })

Section:Paragraph({
    Title = "Состояние",
    Desc = "Меню загружено. Этот файл не запускает ни одного фонового цикла и не обращается к игровым remote."
})

Section:Toggle({
    Title = "Тестовый переключатель",
    Desc = "Меняет только локальное значение внутри этого меню",
    Value = false,
    Callback = function(value)
        env.PSX_OG_MENU_TEST_TOGGLE = value == true
    end
})

local function destroyMenuTest()
    if Window and type(Window.Destroy) == "function" then
        pcall(function() Window:Destroy() end)
    elseif WindUI and type(WindUI.Destroy) == "function" then
        pcall(function() WindUI:Destroy() end)
    end
end

env.PSX_OG_MENU_TEST_CLEANUP = destroyMenuTest

Section:Button({
    Title = "Закрыть тест",
    Icon = "x",
    Callback = function()
        if env.PSX_OG_MENU_TEST_CLEANUP == destroyMenuTest then
            env.PSX_OG_MENU_TEST_CLEANUP = nil
        end
        destroyMenuTest()
    end
})

pcall(function() MainTab:Select() end)
