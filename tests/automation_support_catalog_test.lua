local support = require("../automation_support_module")

assert(support("version") == "1.6.0-lowonline")

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

local inferredIds, _, inferredSummary = support("catalog", {
    Library = {
        Directory = {
            Pets = {
                ["samurai-mythical"] = { rarity = "Mythical" },
                ["samurai-legendary"] = { rarity = "Legendary" },
            },
            Eggs = {
                ["Samurai Egg"] = {
                    drops = {
                        { "samurai-legendary", 0.19 },
                        { "samurai-mythical", 0.01 },
                    },
                },
            },
        },
    },
}, { Force = true, TargetName = "Samurai Dragon" })
assert(inferredIds["samurai-mythical"] == true,
    "Samurai Egg Mythical fallback did not recover Samurai Dragon")
assert(inferredIds["samurai-legendary"] == nil,
    "Samurai Egg fallback leaked a non-Mythical species")
assert(string.find(inferredSummary, "samurai-mythical", 1, true),
    "fallback catalog summary did not expose its resolved directory ID")

support("reset")
local eggAcquired = support("acquire", context, "AutoEgg", "AutoEgg")
local fuseAcquired = support("acquire", context, "FuseMachine", "Machine:Fuse")
local goldAcquired = support("acquire", context, "GoldMachine", "Machine:Gold")
assert(eggAcquired == true and fuseAcquired == true and goldAcquired == true,
    "independent Egg/Fuse/Gold lanes blocked one another")

local secondFuse, fuseOwner =
    support("acquire", context, "OtherFuseWorker", "Machine:Fuse")
assert(secondFuse == false and fuseOwner == "FuseMachine",
    "the Fuse lane failed to serialize a second Fuse owner")

local activeLanes, waiting = support("status", context)
assert(string.find(activeLanes, "AutoEgg=AutoEgg", 1, true)
    and string.find(activeLanes, "Machine:Fuse=FuseMachine", 1, true)
    and string.find(activeLanes, "Machine:Gold=GoldMachine", 1, true),
    "lane status omitted an active independent worker")
assert(waiting == 1, "lane status did not count the blocked same-lane waiter")

assert(support("release", context, "FuseMachine", "Machine:Fuse") == true)
local resumedFuse = support("acquire", context, "OtherFuseWorker", "Machine:Fuse")
assert(resumedFuse == true, "the next Fuse owner did not acquire its released lane")
support("reset")

print("PASS LowOnline catalogs and independent Egg/Fuse/Gold inventory lanes")
