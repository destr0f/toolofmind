local support = require("../automation_support_module")

assert(support("version") == "1.4.0")

local context = {
    Library = {
        Directory = {
            Pets = {
                ["301"] = { name = "Hellish Axolotl", rarity = "Mythical" },
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
                        ["301"] = 0.001,
                        ["288"] = 0.001,
                        ["245"] = 0.001,
                    },
                },
            },
        },
    },
}

local ids, names, summary = support("catalog", context, true)
assert(ids["301"] == true, "machine catalog omitted exact Hellish Axolotl ID")
for _, id in ipairs({ "240", "245", "263", "264", "265", "288" }) do
    assert(ids[id] == nil, "machine catalog broadened beyond Hellish Axolotl: " .. id)
end
assert(#names == 1 and names[1] == "Hellish Axolotl")
assert(string.find(summary, "Hellish Axolotl", 1, true))

local sparseIds, sparseNames, sparseSummary = support("catalog", {
    Library = { Directory = { Pets = {}, Eggs = {} } },
}, true)
assert(next(sparseIds) == nil, "missing live Directory must fail closed")
assert(#sparseNames == 0)
assert(string.find(sparseSummary, "Hellish Axolotl", 1, true))

print("PASS machine catalog resolves exact Hellish Axolotl and fails closed")
