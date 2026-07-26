local support = require("../automation_support_module")

assert(support("version") == "1.2.0-lowonline")

local context = {
    Library = {
        Directory = {
            Pets = {
                ["131"] = { name = "Domortuus", rarity = "Mythical" },
                ["132"] = { Name = "Domortuus", Rarity = "Mythical" },
                [133] = { displayName = "Domortuus", rarity = "mythical" },
                ["240"] = { name = "Galaxy Fox", rarity = "Mythical" },
                ["266"] = {
                    name = "Domortuus",
                    rarity = "Mythical",
                    huge = true,
                },
            },
            Eggs = {},
        },
    },
}

local ids, names, summary = support("catalog", context, true)
for _, id in ipairs({ "131", "132", "133" }) do
    assert(ids[id] == true, "machine catalog omitted pet id " .. id)
end
assert(ids["266"] == nil, "Huge pet bypassed the machine protection")
assert(ids["240"] == nil, "non-Domortuus Mythical bypassed the machine catalog")

assert(#names == 1 and names[1] == "Domortuus",
    "machine catalog must expose exactly the Domortuus species")
assert(string.find(summary, "Domortuus", 1, true))

local sparseIds, sparseNames, sparseSummary = support("catalog", {
    Library = { Directory = { Pets = {}, Eggs = {} } },
}, true)
assert(next(sparseIds) == nil, "machine catalog invented a pinned pet ID")
assert(#sparseNames == 0, "empty Directory.Pets produced a fabricated species")
assert(string.find(sparseSummary, "Domortuus not found", 1, true))

print("PASS LowOnline machine catalog resolves only live Domortuus definitions")
