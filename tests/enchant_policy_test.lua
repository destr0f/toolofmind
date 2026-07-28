local enchant = require("../enchant_module")

local library = {
    Directory = {
        Powers = {
            Coins = {
                canDrop = true,
                tiers = {
                    { title = "Coins I" },
                    { title = "Coins II" },
                    { title = "Coins III" },
                    { title = "Coins IV" },
                    { title = "Coins V" },
                },
            },
            FantasyCoins = {
                canDrop = true,
                tiers = {
                    { title = "Fantasy Coins I" },
                    { title = "Fantasy Coins II" },
                    { title = "Fantasy Coins III" },
                    { title = "Fantasy Coins IV" },
                    { title = "Fantasy Coins V" },
                },
            },
            Teamwork = {
                canDrop = true,
                tiers = {
                    { title = "Teamwork" },
                    { title = "Super Teamwork" },
                },
            },
        },
    },
}

local matched, title = enchant("evaluate", {
    Library = library,
    Pet = {
        e = true,
        powers = {
            { "FantasyCoins", 4 },
            { "Teamwork", 1 },
        },
    },
    Targets = { "Coins V", "Teamwork" },
})
assert(matched == true and title == "Teamwork",
    "multiple selected enchants must use OR semantics")

matched, title = enchant("evaluate", {
    Library = library,
    Pet = {
        e = true,
        powers = {
            { "FantasyCoins", 4 },
        },
    },
    Targets = { "Fantasy Coins IV" },
})
assert(matched == true and title == "Fantasy Coins IV",
    "internal power key/tier must resolve through Directory.Powers title")

matched = enchant("evaluate", {
    Library = library,
    Pet = {
        e = true,
        powers = {
            { "Coins", 3 },
        },
    },
    Targets = { "Coins IV", "Coins V" },
})
assert(matched == false, "a lower tier must not satisfy a selected higher tier")

print("PASS enchant policy resolves live power titles and OR alternatives")
