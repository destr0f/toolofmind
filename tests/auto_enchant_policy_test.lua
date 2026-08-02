local enchant = require("../enchant_module")

local library = {
    Directory = {
        Pets = {
            [288] = { name = "404 Demon", rarity = "Legendary" },
            [900] = { name = "Premium Test", rarity = "Exclusive", isPremium = true },
            [901] = { name = "Mythical Test", rarity = "Mythical" },
        },
        Powers = {
            ["Tech Coins"] = {
                tiers = {
                    { title = "Tech Coins I" }, { title = "Tech Coins II" },
                    { title = "Tech Coins III" }, { title = "Tech Coins IV" },
                    { title = "Tech Coins V" },
                },
            },
            Chests = {
                tiers = {
                    { title = "Chest Breaker I" }, { title = "Chest Breaker II" },
                    { title = "Chest Breaker III" },
                },
            },
            Presents = {
                tiers = {
                    { title = "Gifts I" }, { title = "Gifts II" }, { title = "Gifts III" },
                },
            },
            Teamwork = {
                tiers = { { title = "Teamwork" }, { title = "Super Teamwork" } },
            },
            Royalty = { tiers = { { title = "Royalty" } } },
        },
    },
}

local function matches(pet, targets)
    return enchant("matches", { Library = library, Pet = pet, Targets = targets })
end

local function eligible(pet)
    return enchant("eligible", { Library = library, Pet = pet })
end

assert(matches({ powers = { { "Tech Coins", 5 } } }, { "Tech Coins V" }) == "Tech Coins V")
assert(matches({ powers = { { "Tech Coins", 4 } } }, { "Tech Coins V" }) == nil)
assert(matches({ powers = { { "Royalty", 1 } } }, { "Tech Coins V", "Royalty" }) == "Royalty")
assert(matches({ powers = { { "Teamwork", 2 } } }, { "Super Teamwork" }) == "Super Teamwork")
assert(matches({ powers = { { "Chests", 3 } } }, { "Chest Breaker III" }) == "Chest Breaker III")
assert(matches({ powers = { Presents = "III" } }, { "Gifts III" }) == "Gifts III")
assert(matches({ powers = { "Tech Coins V" } }, { "Tech Coins V" }) == "Tech Coins V")

assert(eligible({ id = 288, uid = "ok", e = true }) == true)
assert(eligible({ id = 288, uid = "off", e = false }) == false)
assert(eligible({ id = 900, uid = "premium", e = true }) == false)
assert(eligible({ id = 901, uid = "mythical", e = true }) == false)

assert(enchant("power-title", { Library = library, Name = "Chests", Level = 2 }) == "Chest Breaker II")
assert(enchant("power-title", { Library = library, Name = "Presents", Level = 3 }) == "Gifts III")
assert(enchant("power-title", { Library = library, Name = "Teamwork", Level = 2 }) == "Super Teamwork")

print("PASS serialized auto-enchant matching and equipped-pet safety policy")
