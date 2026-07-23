local support = require("../automation_support_module")

assert(support("version") == "1.1.0")

local context = {
    Library = {
        Directory = {
            Pets = {
                ["240"] = { name = "Galaxy Fox", rarity = "Mythical" },
                ["241"] = { Name = "Silver Stag", Rarity = "Mythical" },
                [242] = { displayName = "Silver Dragon", rarity = "mythical" },
                ["243"] = { DisplayName = "Santa Paws", rarity = "MYTHICAL" },
                ["244"] = {
                    name = "Santa Paws",
                    rarity = "Mythical",
                    huge = true,
                },
                ["245"] = {
                    name = "Event Mythical Probe",
                    rarity = "Mythical",
                },
            },
            Eggs = {
                ["Christmas Tree Egg"] = {
                    currency = "Gingerbread",
                    -- Live Directory revisions may use [petId] = chance.
                    drops = {
                        ["245"] = 0.001,
                    },
                },
            },
        },
    },
}

local ids, names, summary = support("catalog", context, true)
for _, id in ipairs({ "240", "241", "242", "243", "245" }) do
    assert(ids[id] == true, "machine catalog omitted pet id " .. id)
end
assert(ids["244"] == nil, "Huge pet bypassed the machine protection")

local byName = {}
for _, name in ipairs(names) do byName[name] = true end
for _, name in ipairs({
    "Galaxy Fox",
    "Silver Stag",
    "Silver Dragon",
    "Santa Paws",
    "Event Mythical Probe",
}) do
    assert(byName[name] == true, "machine catalog omitted " .. name)
end

assert(string.find(summary, "Silver Stag", 1, true))
assert(string.find(summary, "Silver Dragon", 1, true))
assert(string.find(summary, "Santa Paws", 1, true))

print("PASS machine catalog resolves all Christmas Mythicals across live Directory schemas")
