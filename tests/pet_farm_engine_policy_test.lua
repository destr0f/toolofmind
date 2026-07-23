local engine = require("../pet_farm_engine")

local pets = { "pet-a", "pet-b", "pet-c" }

local keyed = engine("classify", {
    ["pet-a"] = true,
    ["pet-b"] = false,
    ["pet-c"] = true,
}, pets)
assert(keyed["pet-a"] == true and keyed["pet-c"] == true)
assert(keyed["pet-b"] == nil, "explicit false must remain rejected")

local array = engine("classify", { "pet-b", "pet-c" }, pets)
assert(array["pet-a"] == nil)
assert(array["pet-b"] == true and array["pet-c"] == true,
    "array-shaped Join Coin replies must be recognized")

local nested = engine("classify", {
    accepted = {
        { uid = "pet-a" },
        { PetId = "pet-c" },
    },
}, pets)
assert(nested["pet-a"] == true and nested["pet-c"] == true)
assert(nested["pet-b"] == nil)

local all = engine("classify", true, pets)
assert(all["pet-a"] and all["pet-b"] and all["pet-c"])

local none = engine("classify", false, pets)
assert(next(none) == nil)

assert(math.abs(engine("retry-delay", 1) - 0.06) < 0.0001)
assert(math.abs(engine("retry-delay", 2) - 0.12) < 0.0001)
assert(math.abs(engine("retry-delay", 3) - 0.24) < 0.0001)
assert(math.abs(engine("retry-delay", 9) - 0.24) < 0.0001)

print("PASS pet farm engine recognizes live Join Coin reply shapes")
