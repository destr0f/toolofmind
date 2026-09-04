local gold = require("../gold_machine_module")
local rainbow = require("../rainbow_machine_module")
local darkMatter = require("../dark_matter_module")

local function protected(module, pet)
    local result, level = module("protected-rainbow-coins", pet)
    return result == true, level
end

assert(protected(gold, { powers = { { "Rainbow Coins", 5 } } }) == true)
assert(protected(gold, { powers = { { "Rainbow Coins", 4 } } }) == false)
assert(protected(gold, { powers = { ["Rainbow Coins"] = "V" } }) == true)
assert(protected(gold, { powers = { "Rainbow Coins V" } }) == true)

assert(protected(rainbow, { powers = { { "Rainbow Coins", 5 } } }) == true)
assert(protected(rainbow, { powers = { { "Rainbow Coins", 4 } } }) == false)
assert(protected(rainbow, { Powers = { ["Rainbow Coins"] = "IV" } }) == false)
assert(protected(rainbow, { powers = { "Rainbow Coins V" } }) == true)

assert(protected(darkMatter, { powers = { { "Rainbow Coins", 5 } } }) == true)
assert(protected(darkMatter, { powers = { { "Rainbow Coins", 4 } } }) == false)
assert(protected(darkMatter, { Powers = { ["Rainbow Coins"] = 5 } }) == true)
assert(protected(darkMatter, { powers = { { "Strength", 5 } } }) == false)
assert(protected(darkMatter, { powers = { { "Tech Coins", 5 } } }) == false)

print("PASS Cat target Rainbow Coins protection formats")
