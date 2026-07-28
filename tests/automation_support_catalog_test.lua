local support = require("../automation_support_module")

assert(support("version") == "1.3.0-lowonline")

local context = {
    Library = {
        Directory = {
            Pets = {
                ["131"] = { name = "Domortuus", rarity = "Mythical" },
                ["132"] = { Name = "Domortuus", Rarity = "Mythical" },
                [133] = { displayName = "Domortuus", rarity = "mythical" },
                ["151"] = { name = "Samurai Dragon", rarity = "Mythical" },
                [152] = { displayName = "Samurai Dragon", rarity = "mythical" },
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

local ids, names, summary = support("catalog", context, {
    Force = true,
    TargetName = "Samurai Dragon",
})
for _, id in ipairs({ "151", "152" }) do
    assert(ids[id] == true, "Samurai Dragon catalog omitted pet id " .. id)
end
assert(ids["131"] == nil, "Domortuus leaked into the Samurai Dragon catalog")
assert(#names == 1 and names[1] == "Samurai Dragon")
assert(string.find(summary, "Samurai Dragon", 1, true))

ids, names, summary = support("catalog", context, {
    Force = true,
    TargetName = "Domortuus",
})
for _, id in ipairs({ "131", "132", "133" }) do
    assert(ids[id] == true, "Domortuus catalog omitted pet id " .. id)
end
assert(ids["266"] == nil, "Huge pet bypassed the machine protection")
assert(ids["240"] == nil, "non-Domortuus Mythical bypassed the machine catalog")

assert(#names == 1 and names[1] == "Domortuus",
    "machine catalog must expose exactly the Domortuus species")
assert(string.find(summary, "Domortuus", 1, true))

local sparseIds, sparseNames, sparseSummary = support("catalog", {
    Library = { Directory = { Pets = {}, Eggs = {} } },
}, { Force = true, TargetName = "Samurai Dragon" })
assert(next(sparseIds) == nil, "machine catalog invented a pinned pet ID")
assert(#sparseNames == 0, "empty Directory.Pets produced a fabricated species")
assert(string.find(sparseSummary, "Samurai Dragon not found", 1, true))

print("PASS LowOnline machine catalogs isolate Samurai Dragon and Domortuus")
