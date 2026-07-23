local function exercise(modulePath, pet, infoCommand, actionCommand, darkMatter)
    local machine = require(modulePath)
    assert(machine("version") == "1.0.1")

    local callback
    local calls = {}
    local statuses = {}
    local kernel = {}

    function kernel:Every(_, _, _, worker)
        callback = worker
        return "test-job", true
    end

    function kernel:Unregister()
        return true
    end

    local save = {
        Pets = { pet },
        DarkMatterQueue = {},
        DarkMatterSlots = 1,
    }
    local context = {
        Library = { Directory = { Pets = {} } },
        Kernel = kernel,
        Running = function() return true end,
        Enabled = function() return true end,
        CreateEnabled = function() return true end,
        ClaimEnabled = function() return false end,
        GetSave = function() return save end,
        GetCurrency = function() return 1e15 end,
        FormatNumber = tostring,
        GetMachinePetCatalog = function()
            return { ["263"] = true, ["264"] = true, ["265"] = true },
                { "Santa Paws", "Silver Stag", "Silver Dragon" },
                "pinned current Christmas trio"
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
    callback({ IsCancelled = function() return false end })

    assert(#calls == 1, table.concat(statuses, "\n"))
    assert(calls[1].Command == actionCommand,
        "expected " .. actionCommand .. ", got " .. tostring(calls[1].Command))
    assert(type(calls[1].Uids) == "table" and calls[1].Uids[1] == tostring(pet.uid),
        "machine did not dispatch the sparse-directory pet UID")
    machine("stop")
end

exercise("../gold_machine_module", {
    id = "263",
    uid = "santa-paws-normal",
}, "Get Golden Machine Info", "Use Golden Machine", false)

exercise("../rainbow_machine_module", {
    id = "264",
    uid = "silver-stag-golden",
    g = true,
}, "Get Rainbow Machine Info", "Use Rainbow Machine", false)

exercise("../dark_matter_module", {
    id = "265",
    uid = "silver-dragon-rainbow",
    r = true,
}, "Get Dark Matter Machine Info", "Convert To Dark Matter", true)

print("PASS Gold, Rainbow and Dark Matter accept pinned IDs without Directory.Pets definitions")
