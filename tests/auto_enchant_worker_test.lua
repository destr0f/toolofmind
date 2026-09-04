local enchant = require("../enchant_module")

local queue, delays = {}, {}
local fakeTask = {
    delay = function(seconds, callback)
        delays[#delays + 1] = tonumber(seconds) or 0
        queue[#queue + 1] = callback
    end,
}

local save = {
    Pets = {
        { id = 288, uid = "pet-a", e = false, powers = { { "Strength", 1 } } },
        { id = 288, uid = "pet-b", powers = { { "Agility", 1 } } },
    },
    PetsEquipped = { ["pet-a"] = true, ["pet-b"] = true },
}
local library = {
    Save = { Get = function() return save end },
    Directory = {
        Pets = { [288] = { name = "404 Demon", rarity = "Legendary" } },
        Powers = {
            Strength = { tiers = { { title = "Strength I" } } },
            Agility = { tiers = { { title = "Agility I" } } },
            Royalty = { tiers = { { title = "Royalty" } } },
            ["Tech Coins"] = {
                tiers = {
                    { title = "Tech Coins I" }, { title = "Tech Coins II" },
                    { title = "Tech Coins III" }, { title = "Tech Coins IV" },
                    { title = "Tech Coins V" },
                },
            },
        },
    },
}

local enabled = true
local calls, inFlight, maximumInFlight = {}, 0, 0
local rollsByUID = {}
local function find(uid)
    for _, pet in ipairs(save.Pets) do
        if pet.uid == uid then return pet end
    end
end

local accepted, problem = enchant("start", {
    Library = library,
    Running = function() return true end,
    Enabled = function() return enabled end,
    GetEquippedPetSet = function()
        return save.PetsEquipped, true, nil
    end,
    GetTargets = function() return { "Royalty", "Tech Coins V" } end,
    InvokeCommand = function(command, uid)
        assert(command == "Enchant Pet", "unexpected command")
        inFlight = inFlight + 1
        maximumInFlight = math.max(maximumInFlight, inFlight)
        calls[#calls + 1] = uid
        rollsByUID[uid] = (rollsByUID[uid] or 0) + 1
        local pet = assert(find(uid), "requested pet is missing")
        if uid == "pet-a" and rollsByUID[uid] == 1 then
            pet.powers = { { "Tech Coins", 3 } }
        elseif uid == "pet-a" then
            pet.powers = { { "Royalty", 1 } }
        else
            pet.powers = { { "Tech Coins", 5 } }
        end
        inFlight = inFlight - 1
        return true, true, nil, "test", 1
    end,
    RouteText = function() return "test route" end,
    AcquireOperation = function() return true, "AutoEnchant" end,
    ReleaseOperation = function() return true end,
    CancelOperation = function() return true end,
    OperationOwner = "AutoEnchant",
    GetNetworkPressure = function() return 420, 0.18, 12, 2 end,
    SetStatus = function() end,
    Trace = function() end,
    Task = fakeTask,
})
assert(accepted == true, tostring(problem))

local steps = 0
while #calls < 3 and #queue > 0 and steps < 30 do
    steps = steps + 1
    local callback = table.remove(queue, 1)
    callback()
end
enabled = false
enchant("stop")

assert(#calls == 3, "expected exactly three confirmed rolls")
assert(calls[1] == "pet-a" and calls[2] == "pet-a" and calls[3] == "pet-b",
    "worker did not keep one UID until a selected enchant appeared")
assert(maximumInFlight == 1, "more than one enchant request was in flight")
assert(table.find(delays, 0.55) ~= nil,
    "high-ping farm pressure did not pace the next confirmed enchant roll")
assert(find("pet-a").powers[1][1] == "Royalty", "first pet did not reach a selected enchant")
assert(find("pet-b").powers[1][2] == 5, "second pet did not reach a selected enchant")

print("PASS auto-enchant keeps one UID sticky and serializes every request")
