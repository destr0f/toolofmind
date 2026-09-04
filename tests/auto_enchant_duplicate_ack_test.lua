local enchant = require("../enchant_module")

local queue, delays = {}, {}
local fakeTask = {
    delay = function(seconds, callback)
        delays[#delays + 1] = tonumber(seconds) or 0
        queue[#queue + 1] = callback
    end,
}

local callback
local eventSignal = {}
function eventSignal:Connect(value)
    callback = value
    return { Disconnect = function() callback = nil end }
end

local save = {
    Pets = { { id = 1, uid = "pet-a", powers = { { "Strength", 1 } } } },
    PetsEquipped = { ["pet-a"] = true },
}
local calls = 0
local enabled = true
local accepted, problem = enchant("start", {
    Library = {
        Save = { Get = function() return save end },
        Directory = {
            Pets = { [1] = { name = "Rich Cat", rarity = "Legendary" } },
            Powers = {
                Strength = { tiers = { { title = "Strength I" } } },
                Royalty = { tiers = { { title = "Royalty" } } },
            },
        },
    },
    Running = function() return true end,
    Enabled = function() return enabled end,
    GetEquippedPetSet = function() return save.PetsEquipped, true end,
    GetTargets = function() return { "Royalty" } end,
    GetEventRemote = function(name)
        assert(name == "Enchanted Pets", "wrong acknowledgement route")
        return { OnClientEvent = eventSignal }, "test event", 1
    end,
    InvokeCommand = function(command, uid)
        assert(command == "Enchant Pet" and uid == "pet-a", "wrong enchant request")
        calls = calls + 1
        if calls == 1 then
            callback(uid, { { "Strength", 1 } }) -- valid duplicate result
        else
            save.Pets[1].powers = { { "Royalty", 1 } }
            callback(uid, save.Pets[1].powers)
        end
        return true, true, nil, "test", 1
    end,
    RouteText = function() return "test route" end,
    AcquireOperation = function() return true, "AutoEnchant" end,
    ReleaseOperation = function() return true end,
    CancelOperation = function() return true end,
    OperationOwner = "AutoEnchant",
    GetNetworkPressure = function() return 180, 0.18, 0, 0 end,
    SetStatus = function() end,
    Trace = function() end,
    Task = fakeTask,
})
assert(accepted == true, tostring(problem))

local steps = 0
while calls < 2 and #queue > 0 and steps < 20 do
    steps = steps + 1
    table.remove(queue, 1)()
end
enabled = false
enchant("stop")

assert(calls == 2, "an unchanged but acknowledged roll stalled the worker")
assert(table.find(delays, 0.55) ~= nil, "stable pacing was not applied after event acknowledgement")
assert(not table.find(delays, 8), "legacy eight-second stall remains")

print("PASS duplicate Enchanted Pets acknowledgement stays continuous")
