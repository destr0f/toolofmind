local support = require("../automation_support_module")

assert(support("version") == "1.6.0")

local context = {
    Library = {
        Directory = {
            Pets = {
                ["403"] = { name = "Helicopter Cat", rarity = "Mythical" },
                ["404"] = { name = "Rich Cat", rarity = "Legendary" },
                ["288"] = { name = "404 Demon", rarity = "Mythical" },
                ["245"] = {
                    name = "Event Mythical Probe",
                    rarity = "Mythical",
                },
            },
            Eggs = {},
        },
    },
}

local ids, names, summary = support("catalog", context, true)
assert(ids["403"] == true, "machine catalog omitted exact Helicopter Cat ID")
assert(ids["404"] == true, "machine catalog omitted exact Rich Cat ID")
for _, id in ipairs({ "240", "245", "263", "264", "265", "288", "301" }) do
    assert(ids[id] == nil, "machine catalog broadened beyond Cat targets: " .. id)
end
assert(#names == 2)
assert(table.find(names, "Helicopter Cat") and table.find(names, "Rich Cat"))
assert(string.find(summary, "Helicopter Cat", 1, true))
assert(string.find(summary, "Rich Cat", 1, true))

local sparseIds, sparseNames, sparseSummary = support("catalog", {
    Library = { Directory = { Pets = {}, Eggs = {} } },
}, true)
assert(next(sparseIds) == nil, "missing live Directory must fail closed")
assert(#sparseNames == 0)
assert(string.find(sparseSummary, "Cat World target", 1, true))

print("PASS machine catalog resolves exact Rich Cat and Helicopter Cat and fails closed")
