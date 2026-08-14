local function exercise(modulePath, pet, infoCommand, actionCommand, darkMatter)
    local machine = require(modulePath)
    assert(machine("version") == (darkMatter and "1.5.1" or "1.5.0"))

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
    local context = {
        Library = { Directory = { Pets = { ["404"] = { name = "Pixel Demon" } } } },
        Task = workerTask,
        Running = function() return true end,
        Enabled = function() return enabled end,
        CreateEnabled = function() return true end,
        ClaimEnabled = function() return false end,
        GetSave = function() return save end,
        GetCurrency = function() return 1e15 end,
        FormatNumber = tostring,
        GetMachinePetCatalog = function()
            return { ["404"] = true }, { "Pixel Demon" }, "live exact-name catalog"
        end,
        BatchSize = function() return 1 end,
        MaxWaitSeconds = function() return nil end,
        MatchProtection = function() return "EMPTY", "test has no enchant protection" end,
        MatchCleanupProtection = function() return "EMPTY", "cleanup safe-off" end,
        ProtectionDryRun = function() return false end,
        DMCleanupEnabled = function() return false end,
        DMCleanupScope = function() return "Newly Claimed" end,
        DMCleanupDryRun = function() return true end,
        DMCleanupConfirmed = function() return false end,
        DMCleanupBatchSize = function() return 25 end,
        GetPetSnapshot = function()
            local byUID = {}
            for _, item in ipairs(save.Pets) do byUID[tostring(item.uid)] = item end
            return { Save = save, Pets = save.Pets, ByUID = byUID }
        end,
        InvalidatePetSnapshot = function() end,
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

    assert(#calls == 1, table.concat(statuses, "\n"))
    assert(calls[1].Command == actionCommand,
        "expected " .. actionCommand .. ", got " .. tostring(calls[1].Command))
    assert(type(calls[1].Uids) == "table" and calls[1].Uids[1] == tostring(pet.uid),
        "machine did not dispatch the sparse-directory pet UID")
    machine("stop")
end

exercise("../gold_machine_module", {
    id = "404",
    uid = "pixel-demon-normal",
}, "Get Golden Machine Info", "Use Golden Machine", false)

exercise("../rainbow_machine_module", {
    id = "404",
    uid = "pixel-demon-golden",
    g = true,
}, "Get Rainbow Machine Info", "Use Rainbow Machine", false)

exercise("../dark_matter_module", {
    id = "404",
    uid = "pixel-demon-rainbow",
    r = true,
}, "Get Dark Matter Machine Info", "Convert To Dark Matter", true)

print("PASS Gold, Rainbow and Dark Matter use the live Pixel Demon catalog")
