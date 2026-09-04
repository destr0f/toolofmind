local support = require("../automation_support_module")

assert(support("version") == "1.6.0")

local function profile(rules, revision)
    return { Enabled = true, Revision = revision or 1, Rules = rules }
end

local function rule(...)
    return { Enabled = true, Conditions = { ... } }
end

local function condition(name, mode, level)
    return { Enchant = name, Mode = mode or "Any", Level = level }
end

local pet = {
    uid = "pet-1",
    powers = {
        { "Rainbow Coins", 5 },
        { "Royalty" },
        { "Charm" },
        { "Agility", 2 },
    },
}

local decision, detail = support("match-enchant-profile", {}, {
    Profile = profile({
        rule(condition("Super Teamwork")),
        rule(condition("Royalty"), condition("Charm")),
    }),
    Pet = pet,
})
assert(decision == "MATCH" and detail == "rule 2", "AND/OR matching failed")

decision = support("match-enchant-profile", {}, {
    Profile = profile({ rule(condition("Rainbow Coins", "Exact", 4)) }, 2), Pet = pet,
})
assert(decision == "NO_MATCH", "exact level accepted the wrong tier")

decision = support("match-enchant-profile", {}, {
    Profile = profile({ rule(condition("Rainbow Coins", "IV/V")) }, 3), Pet = pet,
})
assert(decision == "MATCH", "IV/V did not accept tier V")

decision = support("match-enchant-profile", {}, {
    Profile = profile({ rule(condition("Rainbow Coins", "AtLeast", 4)) }, 4), Pet = pet,
})
assert(decision == "MATCH", "AtLeast did not accept tier V")

decision = support("match-enchant-profile", {}, {
    Profile = profile({ rule(condition("Teamwork or Super Teamwork")) }, 5),
    Pet = { uid = "pet-2", powers = { { "Super Teamwork" }, { "Glittering" } } },
})
assert(decision == "MATCH", "Teamwork/STW union did not match STW")

decision = support("match-enchant-profile", {}, {
    Profile = profile({ rule(condition("Royalty")) }, 6),
    Pet = { uid = "pet-3" },
})
assert(decision == "DEFER", "incomplete enchant data must defer")

decision = support("match-enchant-profile", {}, {
    Profile = profile({}, 7), Pet = pet,
})
assert(decision == "EMPTY", "empty machine profile must mean no enchant protection")

decision = support("match-enchant-profile", {}, {
    Profile = { Enabled = false, Revision = 8, Rules = { rule(condition("Royalty")) } },
    Pet = pet,
})
assert(decision == "EMPTY", "disabled profile must mean no enchant protection")

local formula = support("enchant-profile-formula", {}, profile({
    rule(condition("Super Teamwork")),
    rule(condition("Royalty"), condition("Charm")),
}))
assert(string.find(formula, " OR ", 1, true), "formula omitted OR")
assert(string.find(formula, " AND ", 1, true), "formula omitted AND")

print("PASS enchant rules use AND inside, OR between, level modes, DEFER and EMPTY safely")
