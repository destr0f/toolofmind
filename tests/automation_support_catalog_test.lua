local support = require("../automation_support_module")

assert(support("version") == "1.4.1")

local context = {
    Library = {
        Directory = {
            Pets = {
                ["404"] = { name = "Pixel Demon", rarity = "Mythical" },
                ["288"] = { name = "404 Demon", rarity = "Mythical" },
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
                        ["404"] = 0.001,
                        ["288"] = 0.001,
                        ["245"] = 0.001,
                    },
                },
            },
        },
    },
}

local ids, names, summary = support("catalog", context, true)
assert(ids["404"] == true, "machine catalog omitted exact Pixel Demon ID")
for _, id in ipairs({ "240", "245", "263", "264", "265", "288", "301" }) do
    assert(ids[id] == nil, "machine catalog broadened beyond Pixel Demon: " .. id)
end
assert(#names == 1 and names[1] == "Pixel Demon")
assert(string.find(summary, "Pixel Demon", 1, true))

local sparseIds, sparseNames, sparseSummary = support("catalog", {
    Library = { Directory = { Pets = {}, Eggs = {} } },
}, true)
assert(next(sparseIds) == nil, "missing live Directory must fail closed")
assert(#sparseNames == 0)
assert(string.find(sparseSummary, "Pixel Demon", 1, true))

print("PASS machine catalog resolves exact Pixel Demon and fails closed")
