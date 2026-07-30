local gold = require("../gold_machine_module")
local rainbow = require("../rainbow_machine_module")
local darkMatter = require("../dark_matter_module")

local function protected(module, pet)
    local result, level = module("protected-tech-coins", pet)
    return result == true, level
end

assert(protected(gold, { powers = { { "Tech Coins", 5 } } }) == true)
assert(protected(gold, { powers = { { "Tech Coins", 4 } } }) == false)
assert(protected(gold, { powers = { ["Tech Coins"] = "V" } }) == true)
assert(protected(gold, { powers = { "Tech Coins V" } }) == true)

assert(protected(rainbow, { powers = { { "Tech Coins", 4 } } }) == true)
assert(protected(rainbow, { powers = { { "Tech Coins", 3 } } }) == false)
assert(protected(rainbow, { Powers = { ["Tech Coins"] = "IV" } }) == true)
assert(protected(rainbow, { powers = { "Tech Coins V" } }) == true)

assert(protected(darkMatter, { powers = { { "Tech Coins", 4 } } }) == true)
assert(protected(darkMatter, { powers = { { "Tech Coins", 3 } } }) == false)
assert(protected(darkMatter, { Powers = { ["Tech Coins"] = 5 } }) == true)
assert(protected(darkMatter, { powers = { { "Strength", 5 } } }) == false)

print("PASS 404 Demon machine enchant protection formats")
