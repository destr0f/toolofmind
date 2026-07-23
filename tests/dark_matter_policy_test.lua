local darkMatter = require("../dark_matter_module")

local tiers = {
    { cost = 100, waitTime = 120 * 3600 },
    { cost = 200, waitTime = 72 * 3600 },
    { cost = 300, waitTime = 36 * 3600 },
    { cost = 400, waitTime = 12 * 3600 },
    { cost = 500, waitTime = 5 * 3600 },
    { cost = 600, waitTime = 0.5 * 3600 },
}

local exactCount, exactTier, exactPolicy = darkMatter("select-tier", {
    Info = tiers,
    BatchSize = 2,
})
assert(exactCount == 2, "exact-count policy changed the requested batch")
assert(exactTier == tiers[2], "exact-count policy returned the wrong tier")
assert(exactPolicy.MaxWaitSeconds == nil and exactPolicy.TargetMet == true)

local limitedCount, limitedTier, limitedPolicy = darkMatter("select-tier", {
    Info = tiers,
    BatchSize = 1,
    MaxWaitSeconds = 12 * 3600,
})
assert(limitedCount == 4, "12-hour policy should select the four-pet tier")
assert(limitedTier == tiers[4], "12-hour policy returned the wrong tier")
assert(limitedPolicy.AddedPets == 3 and limitedPolicy.TargetMet == true)

local fastestCount, fastestTier, fastestPolicy = darkMatter("select-tier", {
    Info = tiers,
    BatchSize = 3,
    MaxWaitSeconds = 10 * 60,
})
assert(fastestCount == 6, "unreachable time limit should select the fastest available tier")
assert(fastestTier == tiers[6], "fastest available tier was not selected")
assert(fastestPolicy.TargetMet == false)

local alreadyFastCount = darkMatter("select-tier", {
    Info = tiers,
    BatchSize = 5,
    MaxWaitSeconds = 12 * 3600,
})
assert(alreadyFastCount == 5, "time policy should never remove requested pets")

print("PASS Dark Matter count/time policy maps to live machine tiers")
