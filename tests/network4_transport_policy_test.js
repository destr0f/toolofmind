const assert = require("assert");
const fs = require("fs");
const path = require("path");

const root = path.resolve(__dirname, "..");
const source = fs.readFileSync(path.join(root, "slim_farm.lua"), "utf8");
const transport = fs.readFileSync(path.join(root, "network4_transport_module.lua"), "utf8");
const manifest = JSON.parse(fs.readFileSync(path.join(root, "runtime_manifest.json"), "utf8"));

assert.strictEqual(manifest.suite.version, "1.4.1-dev.44");
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

process.stdout.write("Network4 transport policy OK\n");
