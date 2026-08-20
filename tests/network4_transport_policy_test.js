const assert = require("assert");
const fs = require("fs");
const path = require("path");

const root = path.resolve(__dirname, "..");
const source = fs.readFileSync(path.join(root, "slim_farm.lua"), "utf8");
const transport = fs.readFileSync(path.join(root, "network4_transport_module.lua"), "utf8");
const petEngine = fs.readFileSync(path.join(root, "pet_farm_lite_engine.lua"), "utf8");
const autoEgg = fs.readFileSync(path.join(root, "auto_egg_module.lua"), "utf8");
const loot = fs.readFileSync(path.join(root, "loot_reactor.lua"), "utf8");
const manifest = JSON.parse(fs.readFileSync(path.join(root, "runtime_manifest.json"), "utf8"));

assert(manifest.suite.version.startsWith("1.4.1-candidate.54"));
assert(manifest.moduleOrder.includes("networkTransport"));
assert.strictEqual(manifest.modules.networkTransport.path, "network4_transport_module.lua");
assert.strictEqual(manifest.modules.networkTransport.load, "lazy");

assert(transport.includes('"PSXOG:SECRET:NETWORK:VLG:12910259120591716249102"'));
assert(!transport.includes('"mmmmmmevilfanta54125612512416124/Network5/"'));
assert(transport.includes("local function djb2Hash(message)"));
assert(transport.includes('add(routeHash(context, kind, commandName), "current Network5 VLG")'));
assert(transport.includes('add(djb2Hash(commandName), "legacy DJB2")'));
assert(!transport.includes('"duskissexyyyyy123iloveudUsk/Network4/"'));
assert(transport.includes('return resolve(context, 1, commandName)'));
assert(transport.includes('return resolve(context, 2, commandName)'));
assert(transport.includes('return resolveBridge(context, 1, commandName)'));
assert(transport.includes('return resolveBridge(context, 2, commandName)'));
assert(transport.includes('local fired = network and network.Fired'));
assert(transport.includes('local ok, signal = pcall(fired, commandName)'));
assert(transport.includes('local source = "Network5 native Fired signal"'));
assert(transport.includes("rawget(hashMaps[kind], commandName)"));
assert(transport.includes("rawget(map, candidate.Value)"));
assert(transport.includes("rawget(bridgeMaps[bridgeKind], candidate.Value)"));
assert(transport.includes('if action == "invalidate" then'));
assert(transport.includes('if action == "stats" then return stats() end'));
assert(transport.includes("cached.Generation == generation"));
// Cold routes are derived locally. The current layout exposes the remote map as
// upvalue #2, not a callable accessor; invoking it must never be attempted.
assert(!transport.includes("local function nativeBind(context, kind, commandName)"));
assert(transport.includes('remote.GetAttribute, remote, "NetworkHash"'));
assert(transport.includes("pcall(storage.GetChildren, storage)"));
assert(transport.includes('source .. " via NetworkHash attribute"'));
assert(!transport.includes("bridge:Invoke("), "unwired BindableFunction bridges must never be invoked");

assert(source.includes("coinSync.NetworkTransport"));
assert(source.includes('loadRemoteController("networkTransport", "Network4 transport adapter")'));
assert(source.includes('"resolveFireBridge", commandName, "BindableEvent"'));
assert(source.includes('sourceName = "Library.Network.Invoke named fallback"'));
assert(source.includes('sourceName = "Library.Network.Fire named fallback"'));
assert(source.includes('["Get Coins"] = { "Get Coins Data", "Get The Coins", "Get Coins" }'));
assert(!source.includes("pcall(accessor, commandName)"));
assert(!source.includes("pcall(candidate, commandName)"));
assert(!source.includes('"Network.Invoke GetRemoteFunction upvalue #2"'));
assert(!source.includes('"Network.Fire GetRemoteEvent upvalue #2"'));

const invokeBridge = petEngine.indexOf('type(context.GetCommandBridge) == "function"');
const invokeNamed = petEngine.indexOf('type(network.Invoke) ~= "function"');
const fireBridge = petEngine.indexOf('type(context.GetFireBridge) == "function"');
const fireNamed = petEngine.indexOf('type(network.Fire) ~= "function"');
assert(invokeBridge >= 0 && invokeNamed > invokeBridge,
    "pet farm does not prefer the native invoke bridge over named Network.Invoke");
assert(fireBridge >= 0 && fireNamed > fireBridge,
    "pet farm does not prefer the native fire bridge over named Network.Fire");
assert(petEngine.includes('context.NoNamedFallback == true'));
const farmContextStart = source.indexOf(
    "local context = {\n        Running = running,\n        Enabled = function() return config.PetFarm end"
);
const farmContextEnd = source.indexOf("DispatchWidth = 16,", farmContextStart);
assert(farmContextStart >= 0 && farmContextEnd > farmContextStart,
    "pet farm runtime context was not found");
const farmContext = source.slice(farmContextStart, farmContextEnd);
assert(!farmContext.includes("NoNamedFallback"),
    "pet farm keeps the legacy named fallback path available");
assert(!farmContext.includes("GetCommandBridge") && !farmContext.includes("GetFireBridge"),
    "pet farm must not use the RobloxScript-bound native bridge path");

assert(source.includes('FireCommand = fireCommand'));
assert(source.includes('GetEventRemote = getEventRemote'));
assert(source.includes('GetFireRemote = getFireRemote'));
assert(source.includes('pcall(remote.GetAttribute, remote, "NetworkHash")'));
assert(source.includes('coinSync.NetworkTransport:Resolve('));
const coinSignalStart = source.indexOf("local function connectCoinSignals");
const coinSignalEnd = source.indexOf('connect("New Coin"', coinSignalStart);
const coinSignalResolver = source.slice(coinSignalStart, coinSignalEnd);
assert(coinSignalResolver.includes('"resolveInboundEvent"'));
assert(!coinSignalResolver.includes("pcall(network.Fired"),
    "farm lifecycle must keep native inbound resolution inside the transport adapter");
assert(source.includes('CommandRouteCandidates("Get Coins")')
    && source.includes('candidate,\n                "RemoteFunction"'));
assert(source.includes('local sent = pcall(remote.InvokeServer, remote, tostring(record.Id), petIds)'));
assert(!source.includes('pcall(network.Invoke, "Leave Coin"'));
assert(!source.includes('pcall(network.Fire, "Change Pet Target"'));

const eggResolverStart = autoEgg.indexOf('local function resolveOpenEggSignal(context)');
const eggResolverEnd = autoEgg.indexOf('local function restoreHeadlessEventGate', eggResolverStart);
const eggResolver = autoEgg.slice(eggResolverStart, eggResolverEnd);
const directEggEvent = eggResolver.indexOf('pcall(context.GetEventRemote, commandName)');
const fallbackEggEvent = eggResolver.indexOf('pcall(network.Fired, commandName)');
assert(directEggEvent >= 0 && fallbackEggEvent > directEggEvent);
assert(autoEgg.includes('local OPEN_EGG_EVENT_NAMES = { "openegggg", "Open Egg" }'));
assert(autoEgg.includes('acknowledgeOpeningEgg(state, context, pending.Egg, pets)'));
assert(autoEgg.includes('acknowledgeOpeningEgg(state, context, eggName, pets)'));
assert(autoEgg.includes('pcall(context.GetFireRemote, "Opening Egg")'));
assert(!autoEgg.includes('pcall(context.FireCommand, "Opening Egg"'));
assert(!autoEgg.includes('pcall(network.Fire, "Opening Egg"'));

const directLootEvent = loot.indexOf('pcall(context.GetEventRemote, name)');
const fallbackLootEvent = loot.indexOf('pcall(network.Fired, name)');
assert(directLootEvent >= 0 && fallbackLootEvent > directLootEvent);

process.stdout.write("Network4 transport policy OK\n");
