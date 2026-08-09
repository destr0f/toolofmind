const assert = require("assert");
const fs = require("fs");
const path = require("path");

const root = path.resolve(__dirname, "..");
const source = fs.readFileSync(path.join(root, "slim_farm.lua"), "utf8");
const transport = fs.readFileSync(path.join(root, "network4_transport_module.lua"), "utf8");
const autoEgg = fs.readFileSync(path.join(root, "auto_egg_module.lua"), "utf8");
const loot = fs.readFileSync(path.join(root, "loot_reactor.lua"), "utf8");
const manifest = JSON.parse(fs.readFileSync(path.join(root, "runtime_manifest.json"), "utf8"));

assert.strictEqual(manifest.suite.version, "1.4.1-dev.49-minimal.1");
assert(manifest.moduleOrder.includes("networkTransport"));
assert.strictEqual(manifest.modules.networkTransport.path, "network4_transport_module.lua");
assert.strictEqual(manifest.modules.networkTransport.load, "lazy");

assert(transport.includes('"duskissexyyyyy123iloveudUsk/Network4/"'));
assert(transport.includes('return resolve(context, 1, commandName)'));
assert(transport.includes('return resolve(context, 2, commandName)'));
assert(transport.includes("rawget(hashMaps[kind], commandName)"));
assert(transport.includes("rawget(remoteMaps[kind], hash)"));
assert(!transport.includes("pcall(accessor"));
assert(!transport.includes("accessor(commandName"));

assert(source.includes("coinSync.NetworkTransport"));
assert(source.includes('loadRemoteController("networkTransport", "Network4 transport adapter")'));
assert(source.includes('sourceName = "Library.Network.Invoke named fallback"'));
assert(source.includes('sourceName = "Library.Network.Fire named fallback"'));
assert(!source.includes("pcall(accessor, commandName)"));
assert(!source.includes("pcall(candidate, commandName)"));
assert(!source.includes('"Network.Invoke GetRemoteFunction upvalue #2"'));
assert(!source.includes('"Network.Fire GetRemoteEvent upvalue #2"'));

assert(source.includes('FireCommand = fireCommand'));
assert(source.includes('GetEventRemote = getEventRemote'));
assert(source.includes('coinSync.NetworkTransport:Resolve('));
assert(source.includes('"Get Coins",\n            "RemoteFunction"'));
assert(source.includes('local sent = pcall(remote.InvokeServer, remote, tostring(record.Id), petIds)'));
assert(!source.includes('pcall(network.Invoke, "Leave Coin"'));
assert(!source.includes('pcall(network.Fire, "Change Pet Target"'));

const directEggEvent = autoEgg.indexOf('pcall(context.GetEventRemote, commandName)');
const fallbackEggEvent = autoEgg.indexOf('pcall(network.Fired, commandName)');
assert(directEggEvent >= 0 && fallbackEggEvent > directEggEvent);
assert(autoEgg.includes('local OPEN_EGG_EVENT_NAMES = { "openegggg", "Open Egg" }'));
assert(autoEgg.includes('acknowledgeOpeningEgg(context, pending.Egg, pets)'));
assert(autoEgg.includes('acknowledgeOpeningEgg(context, eggName, pets)'));
assert(!autoEgg.includes('pcall(network.Fire, "Opening Egg"'));

const directLootEvent = loot.indexOf('pcall(context.GetEventRemote, name)');
const fallbackLootEvent = loot.indexOf('pcall(network.Fired, name)');
assert(directLootEvent >= 0 && fallbackLootEvent > directLootEvent);

process.stdout.write("Network4 transport policy OK\n");
