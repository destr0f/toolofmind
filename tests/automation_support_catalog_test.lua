local support = require("../automation_support_module")

assert(support("version") == "1.2.0")

local context = {
    Library = {
        Directory = {
            Pets = {
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
                        ["288"] = 0.001,
                        ["245"] = 0.001,
                    },
                },
            },
        },
    },
}

local ids, names, summary = support("catalog", context, true)
assert(ids["288"] == true, "machine catalog omitted 404 Demon ID 288")
for _, id in ipairs({ "240", "245", "263", "264", "265" }) do
    assert(ids[id] == nil, "machine catalog broadened beyond ID 288: " .. id)
end
assert(#names == 1 and names[1] == "404 Demon")
assert(string.find(summary, "404 Demon", 1, true))

local sparseIds, sparseNames, sparseSummary = support("catalog", {
    Library = { Directory = { Pets = {}, Eggs = {} } },
}, true)
assert(sparseIds["288"] == true, "pinned 404 Demon ID depends on Directory.Pets")
assert(#sparseNames == 1 and sparseNames[1] == "404 Demon")
assert(string.find(sparseSummary, "404 Demon", 1, true))

print("PASS machine catalog is hard-pinned to 404 Demon ID 288")
