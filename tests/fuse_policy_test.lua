local fuse = require("../fuse_module")

assert(fuse("version") == "1.2.1-lowonline")

local function exercise(enabledModes, expectedMode, rarity, count)
    local worker
    local enabled = true
    local calls = {}
    local statuses = {}
    local pets = {}
    for index = 1, count do
        pets[#pets + 1] = {
            id = rarity,
            uid = string.lower(rarity) .. "-eligible-" .. tostring(index),
            s = index,
        }
    end
    pets[#pets + 1] = {
        id = rarity,
        uid = string.lower(rarity) .. "-equipped",
        e = true,
    }
    pets[#pets + 1] = {
        id = rarity,
        uid = string.lower(rarity) .. "-locked",
        l = true,
    }
    pets[#pets + 1] = {
        id = rarity,
        uid = string.lower(rarity) .. "-golden-form",
        g = true,
    }

    local save = { Pets = pets }
    local function snapshot()
        local byUID = {}
        for _, pet in ipairs(save.Pets) do byUID[tostring(pet.uid)] = pet end
        return { Save = save, Pets = save.Pets, ByUID = byUID }
    end
    local taskMock = {
        spawn = function(callback)
            worker = callback
            return {}
        end,
        wait = function()
            enabled = false
        end,
    }
    local context = {
        Library = {
            Directory = {
                Eggs = {
                    ["Samurai Egg"] = {
                        drops = {
                            { "Basic", 40 },
                            { "Rare", 16 },
                            { "Epic", 4 },
                        },
                    },
                },
                Pets = {
                    Basic = { rarity = "Basic" },
                    Rare = { rarity = "Rare" },
                    Epic = { rarity = "Epic" },
                },
            },
        },
        Task = taskMock,
        Running = function() return true end,
        Enabled = function() return enabled end,
        Modes = function() return enabledModes end,
        GetPetSnapshot = snapshot,
        InvalidatePetSnapshot = function() end,
        GetCommandRemote = function(command)
            assert(command == "Get Fuse Pets Info")
            return {
                InvokeServer = function()
                    return 1000, 12, 3
                end,
            }, "test", 18
        end,
        InvalidateCommand = function() end,
        InvokeCommand = function(command, uids)
            calls[#calls + 1] = { Command = command, Uids = uids }
            return true, true, nil, "test", 18
        end,
        RouteText = function(source, index)
            return tostring(source) .. " #" .. tostring(index)
        end,
        AcquireOperation = function() return true, "test" end,
        ReleaseOperation = function() return true end,
        CancelOperation = function() return true end,
        OperationOwner = "FuseMachine",
        SetStatus = function(text) statuses[#statuses + 1] = tostring(text) end,
        Trace = function() end,
    }

    local started, problem = fuse("start", context)
    assert(started == true, tostring(problem))
    assert(type(worker) == "function", "fuse worker was not registered")
    worker()

    assert(#calls == 1, table.concat(statuses, "\n"))
    assert(calls[1].Command == "Use Fuse Machine")
    assert(#calls[1].Uids == count, "wrong batch size for " .. expectedMode)
    for _, uid in ipairs(calls[1].Uids) do
        assert(not string.find(uid, "equipped", 1, true), "equipped pet was selected")
        assert(not string.find(uid, "locked", 1, true), "locked pet was selected")
        assert(not string.find(uid, "golden-form", 1, true), "upgraded pet was selected")
    end
    fuse("stop")
end

exercise({ ["10 Basic"] = true }, "10 Basic", "Basic", 10)
exercise({ ["7 Rare"] = true }, "7 Rare", "Rare", 7)
exercise({ ["4 Epic"] = true }, "4 Epic", "Epic", 4)

-- All three toggles may be armed together. The worker deliberately emits only
-- one exact batch per cycle so inventory mutations can be confirmed serially.
exercise({
    ["10 Basic"] = true,
    ["7 Rare"] = true,
    ["4 Epic"] = true,
}, "10 Basic", "Basic", 10)

print("PASS LowOnline fuse modes can be armed together and select one exact safe batch")
