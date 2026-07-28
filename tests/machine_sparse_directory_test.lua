local function exercise(
    modulePath, pet, infoCommand, actionCommand, darkMatter, expectedVersion, expectRequest
)
    local machine = require(modulePath)
    assert(machine("version") == expectedVersion)

    local callback
    local calls = {}
    local statuses = {}
    local enabled = true
    local workerTask = {
        spawn = function(worker) callback = worker end,
        wait = function() enabled = false end,
    }

    local save = {
        Pets = { pet },
        DarkMatterQueue = {},
        DarkMatterSlots = 1,
    }
    local catalogName = darkMatter and "Domortuus" or "Samurai Dragon"
    local catalogId = tostring(pet.id)
    local context = {
        Library = {
            Directory = {
                Pets = {
                    [catalogId] = { name = catalogName, rarity = "Mythical" },
                },
            },
        },
        Task = workerTask,
        Running = function() return true end,
        Enabled = function() return enabled end,
        CreateEnabled = function() return true end,
        ClaimEnabled = function() return false end,
        GetSave = function() return save end,
        GetCurrency = function() return 1e15 end,
        FormatNumber = tostring,
        GetMachinePetCatalog = function()
            return { [catalogId] = true },
                { catalogName },
                "live " .. catalogName .. " catalog"
        end,
        BatchSize = function() return 1 end,
        MaxWaitSeconds = function() return nil end,
        GetCommandRemote = function(command)
            return {
                InvokeServer = function()
                    if command == "Get OSTime" then return os.time() end
                    assert(command == infoCommand, "unexpected info command: " .. tostring(command))
                    if darkMatter then return { { cost = 0, waitTime = 1 } } end
                    return { { cost = 0, chance = 100 } }
                end,
            }, "test", 1
        end,
        InvalidateCommand = function() end,
        InvokeCommand = function(command, uids)
            calls[#calls + 1] = { Command = command, Uids = uids }
            return true, true, nil, "test", 1, 100
        end,
        RouteText = function(source, index)
            return tostring(source) .. " #" .. tostring(index)
        end,
        AcquireOperation = function() return true, "test" end,
        ReleaseOperation = function() return true end,
        CancelOperation = function() return true end,
        OperationOwner = "test-machine",
        SetStatus = function(text) statuses[#statuses + 1] = tostring(text) end,
        Trace = function() end,
    }

    local started, problem = machine("start", context)
    assert(started == true, tostring(problem))
    assert(type(callback) == "function", "machine worker was not registered")
    callback()

    if expectRequest == false then
        assert(#calls == 0, table.concat(statuses, "\n"))
        machine("stop")
        return
    end
    assert(#calls == 1, table.concat(statuses, "\n"))
    assert(calls[1].Command == actionCommand,
        "expected " .. actionCommand .. ", got " .. tostring(calls[1].Command))
    assert(type(calls[1].Uids) == "table" and calls[1].Uids[1] == tostring(pet.uid),
        "machine did not dispatch the sparse-directory pet UID")
    machine("stop")
end

exercise("../gold_machine_module", {
    id = "samurai-dragon",
    uid = "samurai-dragon-normal",
}, "Get Golden Machine Info", "Use Golden Machine", false, "1.3.0-lowonline")

exercise("../rainbow_machine_module", {
    id = "samurai-dragon",
    uid = "samurai-dragon-golden",
    g = true,
}, "Get Rainbow Machine Info", "Use Rainbow Machine", false, "1.4.0-lowonline")

exercise("../dark_matter_module", {
    id = "114",
    uid = "domortuus-rainbow",
    r = true,
}, "Get Dark Matter Machine Info", "Convert To Dark Matter", true, "1.3.0-lowonline")

exercise("../rainbow_machine_module", {
    id = "samurai-dragon",
    uid = "samurai-dragon-golden-coins-iv",
    g = true,
    powers = { { "Coins", "IV" } },
}, "Get Rainbow Machine Info", "Use Rainbow Machine", false, "1.4.0-lowonline")

exercise("../rainbow_machine_module", {
    id = "samurai-dragon",
    uid = "samurai-dragon-golden-coins-v",
    g = true,
    Powers = { Coins = "V" },
}, "Get Rainbow Machine Info", "Use Rainbow Machine", false, "1.4.0-lowonline")

exercise("../dark_matter_module", {
    id = "114",
    uid = "domortuus-rainbow-tech-coins-v",
    r = true,
    powers = { { "Tech Coins", "V" } },
}, "Get Dark Matter Machine Info", "Convert To Dark Matter", true, "1.3.0-lowonline")

print("PASS Samurai Dragon Gold/Rainbow and Domortuus DM catalogs remain isolated")
