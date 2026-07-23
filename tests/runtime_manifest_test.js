const fs = require("fs");
const path = require("path");
const crypto = require("crypto");
const { execFileSync } = require("child_process");

const root = path.resolve(__dirname, "..");
const manifestPath = path.join(root, "runtime_manifest.json");
const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));

function assert(condition, message) {
    if (!condition) throw new Error(message);
}

function git(args, encoding = "utf8") {
    return execFileSync("git", args, {
        cwd: root,
        encoding,
        maxBuffer: 32 * 1024 * 1024,
    });
}

function sha256(buffer) {
    return crypto.createHash("sha256").update(buffer).digest("hex");
}

function djb2(buffer) {
    let hash = 5381 >>> 0;
    for (const byte of buffer) hash = (Math.imul(hash, 33) + byte) >>> 0;
    return hash.toString(16).padStart(8, "0");
}

function verifyIdentity(label, buffer, expected) {
    const actual = { bytes: buffer.length, sha256: sha256(buffer), djb2: djb2(buffer) };
    for (const key of Object.keys(actual)) {
        assert(actual[key] === expected[key],
            `${label}: ${key}=${actual[key]}, manifest=${expected[key]}`);
    }
}

assert(manifest.schemaVersion === 1, "unsupported manifest schema");
assert(manifest.suite && manifest.suite.version, "suite version is absent");
assert(Array.isArray(manifest.moduleOrder), "moduleOrder is absent");
assert(new Set(manifest.moduleOrder).size === manifest.moduleOrder.length,
    "moduleOrder has duplicate entries");
assert(manifest.moduleOrder.length === Object.keys(manifest.modules).length,
    "moduleOrder does not cover every module");

const exactOwners = new Map();
const roots = [];
for (const [category, entry] of Object.entries(manifest.layout)) {
    for (const value of entry.files || []) {
        const file = value.replace(/\\/g, "/");
        assert(!exactOwners.has(file), `${file} is classified twice`);
        assert(fs.existsSync(path.join(root, file)), `${category} file is missing: ${file}`);
        exactOwners.set(file, category);
    }
    for (const value of entry.roots || []) {
        roots.push({ category, prefix: value.replace(/\\/g, "/").replace(/\/*$/, "/") });
    }
}

const repositoryFiles = git(["ls-files"]).split(/\r?\n/).filter(Boolean)
    .map((file) => file.replace(/\\/g, "/"));
for (const file of repositoryFiles) {
    const owners = [];
    if (exactOwners.has(file)) owners.push(exactOwners.get(file));
    for (const candidate of roots) {
        if (file.startsWith(candidate.prefix)) owners.push(candidate.category);
    }
    assert(new Set(owners).size === 1,
        `${file} must belong to exactly one layout category; got ${owners.join(", ") || "none"}`);
}

for (const key of manifest.moduleOrder) {
    const entry = manifest.modules[key];
    assert(entry && entry.id === key, `invalid module entry ${key}`);
    assert(entry.compatibleSuite === manifest.suite.version, `${key} suite mismatch`);
    assert(exactOwners.get(entry.path) === "source", `${key} is not active source`);
    const pinned = git(["show", `${entry.commit}:${entry.path}`], null);
    verifyIdentity(`${key} pinned blob`, pinned, entry);
    verifyIdentity(`${key} local source`, fs.readFileSync(path.join(root, entry.path)), entry);
}

assert(exactOwners.get(manifest.windUI.vendorPath) === "vendor", "WindUI is not vendor-classified");
assert(manifest.windUI.compatibleSuite === manifest.suite.version, "WindUI suite mismatch");
verifyIdentity("WindUI", fs.readFileSync(path.join(root, manifest.windUI.vendorPath)), manifest.windUI);

const source = fs.readFileSync(path.join(root, manifest.suite.sourceEntry));
const sourceText = source.toString("utf8");
const sourceVersion = sourceText.match(/local\s+VERSION\s*=\s*["']([^"']+)["']/);
assert(sourceVersion && sourceVersion[1] === manifest.suite.version, "source VERSION differs from manifest");
assert(sourceText.includes("__PSX_RUNTIME_MANIFEST__"), "source manifest marker is absent");
assert(!sourceText.includes("RAW_MODULE_BASE"), "source still has a second module URL registry");
verifyIdentity("source", source, manifest.build.source);
if (process.env.PSX_ALLOW_DIRTY_MANIFEST !== "1") {
    assert(manifest.build.sourceTree === "clean", "release artifacts were built from a dirty source tree");
}
assert(/^[0-9a-f]{40}$/.test(manifest.build.generatedFromCommit || ""),
    "generatedFromCommit is not an exact commit");

const loader = fs.readFileSync(path.join(root, manifest.build.artifacts.loader.path));
const tool = fs.readFileSync(path.join(root, manifest.build.artifacts.toolofmind.path));
assert(loader.equals(tool), "loader.lua and toolofmind.lua are not the same generated artifact");
verifyIdentity("loader artifact", loader, manifest.build.artifacts.loader);
verifyIdentity("toolofmind artifact", tool, manifest.build.artifacts.toolofmind);

const artifactText = tool.toString("utf8");
assert(!artifactText.includes("__PSX_RUNTIME_MANIFEST__"), "generated artifact still contains the marker");
assert(artifactText.includes(manifest.suite.version), "generated artifact omits the suite version");
assert(artifactText.includes(manifest.build.generatedFromCommit), "generated artifact omits its source commit");
assert(artifactText.includes(manifest.build.embeddedRuntimeFingerprint.sha256),
    "generated artifact omits its manifest fingerprint");
for (const key of manifest.moduleOrder) {
    assert(artifactText.includes(manifest.modules[key].sha256),
        `generated artifact omits ${key} identity`);
}

for (const key of manifest.moduleOrder) {
    const entry = manifest.modules[key];
    assert(exactOwners.get(entry.path) !== "legacy", `active module ${key} is marked legacy`);
}
assert(exactOwners.get(manifest.suite.runtimeEntry) === "generated",
    "runtime entry is not generated-classified");

process.stdout.write(
    `Runtime manifest OK | suite=${manifest.suite.version}`
    + ` | modules=${manifest.moduleOrder.length}`
    + ` | source=${manifest.build.source.sha256}`
    + ` | artifact=${manifest.build.artifacts.toolofmind.sha256}\n`
);
