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

assert(transport.includes('"mmmmmmevilfanta54125612512416124/Network5/"'));
assert(transport.includes("local function djb2Hash(message)"));
assert(transport.includes('add(djb2Hash(commandName), "current DJB2")'));
assert(!transport.includes('"duskissexyyyyy123iloveudUsk/Network4/"'));
assert(transport.includes('return resolve(context, 1, commandName)'));
assert(transport.includes('return resolve(context, 2, commandName)'));
assert(transport.includes('return resolveBridge(context, 1, commandName)'));
assert(transport.includes('return resolveBridge(context, 2, commandName)'));
assert(transport.includes("rawget(hashMaps[kind], commandName)"));
assert(transport.includes("rawget(remoteMaps[kind], candidate.Value)"));
assert(transport.includes("rawget(bridgeMaps[bridgeKind], candidate.Value)"));
assert(transport.includes('if action == "invalidate" then'));
assert(transport.includes('if action == "stats" then return stats() end'));
assert(transport.includes("cached.Generation == generation"));
// The only permitted accessor execution is the bounded last-resort lazy bind:
// the game's own u14/u18-style closures perform FindFirstChild + rename + wire
// locally and send no traffic. Blind per-request accessor calls stay banned.
assert(transport.includes("local function nativeBind(context, kind, commandName)"));
assert(transport.includes("readUpvalue(context, method, 2)"),
    "lazy bind must call only the direct remote accessor; the other upvalues create unwired stand-ins");
assert(transport.includes('hashSource = "native lazy bind #" .. tostring(bindIndex)'));
assert(!transport.includes("bridge:Invoke("), "unwired BindableFunction bridges must never be invoked");

assert(source.includes("coinSync.NetworkTransport"));
assert(source.includes('loadRemoteController("networkTransport", "Network4 transport adapter")'));
assert(source.includes('"resolveFireBridge", commandName, "BindableEvent"'));
assert(!source.includes('sourceName = "Library.Network.Invoke named fallback"'),
    "the u11-blocked named invoke fallback must not fake server rejections");
assert(!source.includes('sourceName = "Library.Network.Fire named fallback"'),
    "the u11-blocked named fire fallback must not fake delivery");
assert(source.includes("Network4 transport module is still loading"),
    "startup requests must surface an honest transport-loading state");
assert(source.includes('["Get Coins"] = { "Get The Coins", "Get Coins" }'));
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
assert(farmContext.includes("NoNamedFallback = true"),
    "pet farm must prefer a bounded transport retry over the blocked named fallback");
assert(!farmContext.includes("GetCommandBridge") && !farmContext.includes("GetFireBridge"),
    "pet farm must not use the RobloxScript-bound native bridge path");

assert(source.includes('FireCommand = fireCommand'));
assert(source.includes('GetEventRemote = getEventRemote'));
assert(source.includes('GetFireRemote = getFireRemote'));
assert(source.includes('coinSync.NetworkTransport:Resolve('));
assert(source.includes('CommandRouteCandidates("Get Coins")')
    && source.includes('candidate,\n                "RemoteFunction"'));
assert(source.includes('local sent = pcall(remote.InvokeServer, remote, tostring(record.Id), petIds)'));
assert(!source.includes('pcall(network.Invoke, "Leave Coin"'));
assert(!source.includes('pcall(network.Fire, "Change Pet Target"'));

const eggResolverStart = autoEgg.indexOf('local function resolveOpenEggSignal(context)');
const eggResolverEnd = autoEgg.indexOf('local function restoreHeadlessEventGate', eggResolverStart);
const eggResolver = autoEgg.slice(eggResolverStart, eggResolverEnd);
assert(eggResolver.includes('pcall(context.GetEventRemote, commandName)'),
    "egg hatch event must try the direct RemoteEvent first");
assert(eggResolver.includes('pcall(context.GetInboundSignal, commandName)'),
    "egg hatch event must fall back to the exact t4/t2[1] inbound signal");
assert(!eggResolver.includes('pcall(network.Fired, commandName)'),
    "the injected Fired accessor returns an orphaned bindable and is banned");
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
