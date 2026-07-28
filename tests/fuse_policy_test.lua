local fuse = require("../fuse_module")

assert(fuse("version") == "1.5.1-lowonline")

local function exercise(
    enabledModes,
    expectedMode,
    rarity,
    count,
    speciesId,
    speciesName,
    otherSpeciesId,
    otherSpeciesName,
    otherCount
)
    speciesId = speciesId or rarity
    speciesName = speciesName or speciesId
    local worker
    local enabled = true
    local calls = {}
    local statuses = {}
    local releaseCalls = 0
    local pets = {}
    for index = 1, count do
        pets[#pets + 1] = {
            id = speciesId,
            uid = string.lower(speciesId) .. "-eligible-" .. tostring(index),
            s = index,
        }
    end
    for index = 1, tonumber(otherCount) or 0 do
        pets[#pets + 1] = {
            id = otherSpeciesId,
            uid = string.lower(otherSpeciesId) .. "-other-" .. tostring(index),
            s = index,
        }
    end
    pets[#pets + 1] = {
        id = speciesId,
        uid = string.lower(speciesId) .. "-equipped",
        e = true,
    }
    pets[#pets + 1] = {
        id = speciesId,
        uid = string.lower(speciesId) .. "-locked",
        l = true,
    }
    pets[#pets + 1] = {
        id = speciesId,
        uid = string.lower(speciesId) .. "-golden-form",
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
                        drops = otherSpeciesId
                            and { { speciesId, 40 }, { otherSpeciesId, 20 } }
                            or { { speciesId, 40 } },
                    },
                },
                Pets = {
                    [speciesId] = { name = speciesName, rarity = rarity },
                    [otherSpeciesId or "__none"] = {
                        name = otherSpeciesName,
                        rarity = rarity,
                    },
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
        ReleaseOperation = function()
            releaseCalls = releaseCalls + 1
            return true
        end,
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
    assert(releaseCalls == 1,
        "Fuse retained its inventory lock while waiting for Save.Pets confirmation")
    assert(string.find(statuses[#statuses] or "", expectedMode, 1, true),
        "accepted status omitted mode " .. expectedMode)
    for _, uid in ipairs(calls[1].Uids) do
        assert(string.sub(uid, 1, #string.lower(speciesId)) == string.lower(speciesId),
            "one Fuse request mixed different species")
        assert(not string.find(uid, "equipped", 1, true), "equipped pet was selected")
        assert(not string.find(uid, "locked", 1, true), "locked pet was selected")
        assert(not string.find(uid, "golden-form", 1, true), "upgraded pet was selected")
    end
    fuse("stop")
end

exercise({ ["11 Panda"] = true }, "11 Panda", "Basic", 11, "panda", "Panda")
exercise({ ["10 Axolotl"] = true }, "10 Axolotl", "Basic", 10, "axolotl", "Axolotl")
exercise({ ["9 Tiger"] = true }, "9 Tiger", "Basic", 9, "white-tiger", "White Tiger")
exercise(
    { ["7 Any Rare"] = true },
    "7 Any Rare",
    "Rare",
    7,
    "samurai-dog",
    "Samurai Dog",
    "samurai-cat",
    "Samurai Cat",
    6
)
exercise(
    { ["4 Any Epic"] = true },
    "4 Any Epic",
    "Epic",
    4,
    "samurai-bull",
    "Samurai Bull",
    "samurai-dragon",
    "Samurai Dragon",
    3
)

-- All five toggles may be armed together. The worker deliberately emits only
-- one exact batch per cycle so inventory mutations can be confirmed serially.
exercise({
    ["11 Panda"] = true,
    ["10 Axolotl"] = true,
    ["9 Tiger"] = true,
    ["7 Any Rare"] = true,
    ["4 Any Epic"] = true,
}, "11 Panda", "Basic", 11, "panda", "Panda")

print("PASS LowOnline Fuse exposes five Samurai Egg modes without mixing species")
