local darkMatter = require("../dark_matter_module")

local function decide(pet, values)
    values = values or {}
    values.Pet = pet
    values.IsTarget = values.IsTarget ~= false
    values.Scope = values.Scope or "All Dark Matter Pets"
    return darkMatter("cleanup-policy", values)
end

local base = { uid = "dm-1", id = "404", dm = true, powers = {} }
assert(decide(base, { MatchDecision = "MATCH" }) == "KEEP")
assert(decide(base, { MatchDecision = "NO_MATCH" }) == "DELETE")
assert(decide(base, { MatchDecision = "DEFER" }) == "DEFER")
assert(decide(base, { MatchDecision = "EMPTY" }) == "DISABLED")
assert(decide({ uid = "dm-2", id = "404", dm = true, e = true }, {
    MatchDecision = "NO_MATCH",
}) == "KEEP")
assert(decide({ uid = "dm-3", id = "404", dm = true, l = true }, {
    MatchDecision = "NO_MATCH",
}) == "KEEP")
assert(decide(base, {
    Scope = "Newly Claimed", IsNew = false, MatchDecision = "NO_MATCH",
}) == "SKIP")
assert(decide(base, {
    Scope = "Newly Claimed", IsNew = true, MatchDecision = "NO_MATCH",
}) == "DELETE")
assert(decide(base, {
    AlreadyHandled = true, MatchDecision = "NO_MATCH",
}) == "SKIP")
assert(decide({ id = "404", dm = true }, { MatchDecision = "NO_MATCH" }) == "DEFER")

print("PASS DM cleanup keeps protected/equipped/locked pets and deletes only fresh NO_MATCH candidates")
