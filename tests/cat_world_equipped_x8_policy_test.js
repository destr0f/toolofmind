const fs = require("fs");
const path = require("path");

const root = path.resolve(__dirname, "..");
const read = (file) => fs.readFileSync(path.join(root, file), "utf8");
const assert = (condition, message) => {
    if (!condition) throw new Error(message);
};

const farm = read("slim_farm.lua");
const egg = read("auto_egg_module.lua");
const ui = read("automation_ui_module.lua");
const support = read("automation_support_module.lua");
const petConsumers = [
    "gold_machine_module.lua",
    "rainbow_machine_module.lua",
    "dark_matter_module.lua",
    "enchant_module.lua",
];

assert(farm.includes("save.HardcorePetsEquipped")
    && farm.includes("save.PetsEquipped")
    && farm.includes("token.ReadAuthoritativeEquippedSet"),
"farm does not use the native authoritative equipped membership maps");
assert(farm.includes("petCacheValid = ready == true"),
    "a missing equipped map can still be cached as permanently empty");

for (const file of petConsumers) {
    const source = read(file);
    assert(source.includes("GetEquippedPetSet"),
        `${file} is not wired to authoritative equipped membership`);
    assert(!source.includes("pet.e"),
        `${file} still trusts the stale per-pet equipped marker`);
}

assert(support.includes('["rich cat"] = "Rich Cat"')
    && support.includes('["helicopter cat"] = "Helicopter Cat"'),
    "Cat World conversion targets are incomplete");
assert(farm.includes('["Cat World"] = { "Cat Paradise", "Cat Backyard", "Cat Taiga", "Cat Kingdom" }')
    && farm.includes('["giant cat chest"] = "Cat Kingdom"'),
    "Cat World area/chest map is stale");

for (const route of [
    '["Get Coins"] = { "Get Coins Data"',
    '["Change Pet Target"] = { "Change Pet Target NOW"',
    '["Join Coin"] = { "Join Coin mmm"',
    '["Farm Coin"] = { "Farm Coin mmm"',
    '["Leave Coin"] = { "Leave Coin mmm"',
    '["Buy Egg Yay"] = { "Egg: Buy Egg"',
]) {
    assert(farm.includes(route), `fresh Cobalt route is missing: ${route}`);
}

assert(egg.includes("save.OwnsOctupleEggs")
    && egg.includes('"Buy Egg Yay", pending.Egg, pending.Triple, pending.Octuple'),
    "native x8 ownership/request protocol is missing");
assert(ui.includes('Values = { "Single (x1)", "Triple (x3)", "Octuple (x8)" }'),
    "x8 is not exposed in the egg UI");

process.stdout.write(
    "Cat World policy OK | equip=Save membership | remotes=fresh | machines=Rich+Helicopter | egg=x8\n"
);
