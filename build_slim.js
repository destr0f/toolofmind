const fs = require("fs");
const path = require("path");
const crypto = require("crypto");
const { execFileSync } = require("child_process");

const root = __dirname;
const sourcePath = path.join(root, "slim_farm.lua");
const loaderPath = path.join(root, "loader.lua");
const toolPath = path.join(root, "toolofmind.lua");
const manifestPath = path.join(root, "runtime_manifest.json");
const manifestMarker = "nil --[[__PSX_RUNTIME_MANIFEST__]]";

function fail(message) {
    throw new Error(`Runtime manifest validation failed: ${message}`);
}

function sha256(buffer) {
    return crypto.createHash("sha256").update(buffer).digest("hex");
}

function djb2(buffer) {
    let hash = 5381 >>> 0;
    for (const byte of buffer) hash = (Math.imul(hash, 33) + byte) >>> 0;
    return hash.toString(16).padStart(8, "0");
}

function identity(buffer) {
    return { bytes: buffer.length, sha256: sha256(buffer), djb2: djb2(buffer) };
}

function assertIdentity(label, buffer, expected) {
    const actual = identity(buffer);
    for (const key of ["bytes", "sha256", "djb2"]) {
        if (actual[key] !== expected[key]) {
            fail(`${label} ${key} is ${actual[key]}, expected ${expected[key]}`);
        }
    }
    return actual;
}

function git(args, options = {}) {
    return execFileSync("git", args, {
        cwd: root,
        encoding: options.encoding === null ? null : "utf8",
        maxBuffer: 32 * 1024 * 1024,
    });
}

function normalizePath(value) {
    return String(value).replace(/\\/g, "/").replace(/^\.\//, "");
}

function validateLayout(manifest) {
    const layout = manifest.layout;
    if (!layout || typeof layout !== "object") fail("layout is missing");

    const exactOwners = new Map();
    const roots = [];
    for (const [category, entry] of Object.entries(layout)) {
        if (!entry || typeof entry !== "object") fail(`layout.${category} is invalid`);
        for (const fileValue of entry.files || []) {
            const file = normalizePath(fileValue);
            if (exactOwners.has(file)) {
                fail(`${file} is listed in both ${exactOwners.get(file)} and ${category}`);
            }
            if (!fs.existsSync(path.join(root, file))) fail(`${category} file is missing: ${file}`);
            exactOwners.set(file, category);
        }
        for (const rootValue of entry.roots || []) {
            const prefix = normalizePath(rootValue).replace(/\/*$/, "/");
            if (!fs.existsSync(path.join(root, prefix))) fail(`${category} root is missing: ${prefix}`);
            roots.push({ prefix, category });
        }
    }

    const repositoryFiles = git(["ls-files", "--cached", "--others", "--exclude-standard"])
        .split(/\r?\n/).map(normalizePath).filter(Boolean);
    for (const file of repositoryFiles) {
        const owners = [];
        if (exactOwners.has(file)) owners.push(exactOwners.get(file));
        for (const candidate of roots) {
            if (file.startsWith(candidate.prefix)) owners.push(candidate.category);
        }
        const uniqueOwners = [...new Set(owners)];
        if (uniqueOwners.length === 0) fail(`unclassified repository file: ${file}`);
        if (uniqueOwners.length > 1) fail(`${file} matches multiple categories: ${uniqueOwners.join(", ")}`);
    }

    return exactOwners;
}

function validateManifest(manifest) {
    if (manifest.schemaVersion !== 1) fail(`unsupported schema ${manifest.schemaVersion}`);
    if (!manifest.suite || typeof manifest.suite.version !== "string") fail("suite.version is missing");
    if (!manifest.repository || !manifest.repository.owner || !manifest.repository.name) {
        fail("repository coordinates are missing");
    }

    const owners = validateLayout(manifest);
    const order = manifest.moduleOrder;
    const modules = manifest.modules;
    if (!Array.isArray(order) || !modules || typeof modules !== "object") {
        fail("moduleOrder/modules are missing");
    }
    if (new Set(order).size !== order.length) fail("moduleOrder contains duplicates");
    if (order.length !== Object.keys(modules).length) fail("moduleOrder does not cover every module");

    for (const key of order) {
        const entry = modules[key];
        if (!entry) fail(`moduleOrder references unknown module ${key}`);
        if (entry.id !== key) fail(`${key}.id does not match its manifest key`);
        if (entry.compatibleSuite !== manifest.suite.version) {
            fail(`${key} is compatible with ${entry.compatibleSuite}, not ${manifest.suite.version}`);
        }
        if (!/^[0-9a-f]{40}$/.test(entry.commit || "")) fail(`${key}.commit is not an exact Git commit`);
        if (owners.get(normalizePath(entry.path)) !== "source") fail(`${key}.path is not classified as source`);

        const pinned = git(["show", `${entry.commit}:${entry.path}`], { encoding: null });
        assertIdentity(`${key} pinned blob`, pinned, entry);
        const local = fs.readFileSync(path.join(root, entry.path));
        assertIdentity(`${key} local source`, local, entry);

        if (String(entry.versionAuthority).includes("source-constant")
            || entry.versionAuthority === "module-api") {
            const escaped = entry.version.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
            const declaration = new RegExp(`local\\s+MODULE_VERSION\\s*=\\s*[\"']${escaped}[\"']`);
            if (!declaration.test(pinned.toString("utf8"))) {
                fail(`${key} does not declare MODULE_VERSION ${entry.version}`);
            }
        }
        if (entry.versionAction && !pinned.toString("utf8").includes(`action == "${entry.versionAction}"`)) {
            fail(`${key} does not expose its declared ${entry.versionAction} action`);
        }
    }

    const unknownKeys = Object.keys(modules).filter((key) => !order.includes(key));
    if (unknownKeys.length) fail(`modules omitted from moduleOrder: ${unknownKeys.join(", ")}`);

    const wind = manifest.windUI;
    if (!wind || wind.compatibleSuite !== manifest.suite.version) fail("WindUI compatibility is invalid");
    if (owners.get(normalizePath(wind.vendorPath)) !== "vendor") fail("WindUI copy is not classified as vendor");
    assertIdentity("vendored WindUI", fs.readFileSync(path.join(root, wind.vendorPath)), wind);
}

function luaString(value) {
    return JSON.stringify(value)
        .replace(/\\u2028/g, "\\226\\128\\168")
        .replace(/\\u2029/g, "\\226\\128\\169");
}

function toLua(value, indent = "") {
    if (value === null || value === undefined) return "nil";
    if (typeof value === "string") return luaString(value);
    if (typeof value === "number" || typeof value === "boolean") return String(value);
    const next = indent + "    ";
    if (Array.isArray(value)) {
        if (value.length === 0) return "{}";
        return `{\n${value.map((item) => `${next}${toLua(item, next)},`).join("\n")}\n${indent}}`;
    }
    const entries = Object.entries(value);
    if (entries.length === 0) return "{}";
    return `{\n${entries.map(([key, item]) => {
        const field = /^[A-Za-z_][A-Za-z0-9_]*$/.test(key) ? key : `[${luaString(key)}]`;
        return `${next}${field} = ${toLua(item, next)},`;
    }).join("\n")}\n${indent}}`;
}

const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8").replace(/^\uFEFF/, ""));
validateManifest(manifest);

const rawSource = fs.readFileSync(sourcePath, "utf8").replace(/^\uFEFF/, "");
const versionMatch = rawSource.match(/local\s+VERSION\s*=\s*["']([^"']+)["']/);
if (!versionMatch || versionMatch[1] !== manifest.suite.version) {
    fail(`slim_farm.lua VERSION is ${versionMatch && versionMatch[1]}, expected ${manifest.suite.version}`);
}
if (!rawSource.includes(manifestMarker)) fail("slim_farm.lua runtime manifest marker is missing");
if (rawSource.indexOf(manifestMarker) !== rawSource.lastIndexOf(manifestMarker)) {
    fail("slim_farm.lua contains more than one runtime manifest marker");
}

const sourceIdentity = identity(Buffer.from(rawSource, "utf8"));
const sourceCodePaths = [
    "slim_farm.lua",
    ...(manifest.layout.build.files || []),
    ...manifest.moduleOrder.map((key) => manifest.modules[key].path),
    manifest.windUI.vendorPath,
].filter((value, index, values) => values.indexOf(value) === index);
const sourceCommit = git(["log", "-1", "--format=%H", "--", ...sourceCodePaths]).trim();
const releaseInputPaths = [
    ...sourceCodePaths,
    "runtime_manifest.json",
    ...(manifest.layout.tests.files || []),
    ...(manifest.layout.documentation.files || []),
].filter((value, index, values) => values.indexOf(value) === index);
const sourceTree = git([
    "status", "--porcelain", "--", ...releaseInputPaths,
]).trim() === "" ? "clean" : "dirty";

const embeddedManifest = {
    schemaVersion: manifest.schemaVersion,
    suite: manifest.suite,
    repository: manifest.repository,
    windUI: manifest.windUI,
    moduleOrder: manifest.moduleOrder,
    modules: manifest.modules,
    build: {
        sourceCommit,
        sourceTree,
        source: sourceIdentity,
    },
};
const embeddedBytes = Buffer.from(JSON.stringify(embeddedManifest), "utf8");
embeddedManifest.fingerprint = identity(embeddedBytes);
const buildSource = rawSource.replace(manifestMarker, toLua(embeddedManifest));

const operators = [
    "...", "..=", "//=", "<<=", ">>=", "==", "~=", "<=", ">=", "+=", "-=",
    "*=", "/=", "%=", "^=", "&=", "|=", "..", "//", "::", "->", "<<", ">>",
];

function longBracketEnd(text, start) {
    if (text[start] !== "[") return null;
    let cursor = start + 1;
    while (text[cursor] === "=") cursor++;
    if (text[cursor] !== "[") return null;
    const close = "]" + "=".repeat(cursor - start - 1) + "]";
    const end = text.indexOf(close, cursor + 1);
    return end < 0 ? text.length : end + close.length;
}

function tokenize(text) {
    const result = [];
    let index = 0;
    const push = (type, start, end) => result.push({ type, text: text.slice(start, end) });

    while (index < text.length) {
        const ch = text[index];
        if (/\s/.test(ch)) {
            index++;
            continue;
        }

        if (ch === "-" && text[index + 1] === "-") {
            const blockEnd = longBracketEnd(text, index + 2);
            if (blockEnd !== null) {
                index = blockEnd;
            } else {
                index += 2;
                while (index < text.length && text[index] !== "\n" && text[index] !== "\r") index++;
            }
            continue;
        }

        if (ch === "\"" || ch === "'" || ch === "`") {
            const start = index++;
            while (index < text.length) {
                if (text[index] === "\\") {
                    index += 2;
                } else if (text[index] === ch) {
                    index++;
                    break;
                } else {
                    index++;
                }
            }
            push("string", start, index);
            continue;
        }

        const bracketEnd = longBracketEnd(text, index);
        if (bracketEnd !== null) {
            push("string", index, bracketEnd);
            index = bracketEnd;
            continue;
        }

        if (/[A-Za-z_]/.test(ch)) {
            const start = index++;
            while (index < text.length && /[A-Za-z0-9_]/.test(text[index])) index++;
            push("word", start, index);
            continue;
        }

        if (/[0-9]/.test(ch) || (ch === "." && /[0-9]/.test(text[index + 1] || ""))) {
            const start = index;
            if (ch === "0" && /[xX]/.test(text[index + 1] || "")) {
                index += 2;
                while (/[0-9A-Fa-f_]/.test(text[index] || "")) index++;
                if (text[index] === "." && text[index + 1] !== ".") {
                    index++;
                    while (/[0-9A-Fa-f_]/.test(text[index] || "")) index++;
                }
                if (/[pP]/.test(text[index] || "")) {
                    index++;
                    if (/[+-]/.test(text[index] || "")) index++;
                    while (/[0-9_]/.test(text[index] || "")) index++;
                }
            } else if (ch === "0" && /[bB]/.test(text[index + 1] || "")) {
                index += 2;
                while (/[01_]/.test(text[index] || "")) index++;
            } else {
                if (ch === ".") index++;
                while (/[0-9_]/.test(text[index] || "")) index++;
                if (text[index] === "." && text[index + 1] !== ".") {
                    index++;
                    while (/[0-9_]/.test(text[index] || "")) index++;
                }
                if (/[eE]/.test(text[index] || "")) {
                    index++;
                    if (/[+-]/.test(text[index] || "")) index++;
                    while (/[0-9_]/.test(text[index] || "")) index++;
                }
            }
            push("number", start, index);
            continue;
        }

        const operator = operators.find((candidate) => text.startsWith(candidate, index));
        if (operator) {
            push("symbol", index, index + operator.length);
            index += operator.length;
        } else {
            push("symbol", index, index + 1);
            index++;
        }
    }
    return result;
}

function canJoin(left, right) {
    // Luau treats a decimal immediately followed by an identifier as one
    // malformed numeric token (for example `4local`), even though this small
    // tokenizer can split the pair. Keep an explicit lexical boundary here.
    if (left.type === "number" && (right.type === "word" || right.text.startsWith("."))) {
        return false;
    }
    const joined = tokenize(left.text + right.text);
    return joined.length === 2
        && joined[0].type === left.type && joined[0].text === left.text
        && joined[1].type === right.type && joined[1].text === right.text;
}

const tokens = tokenize(buildSource);
let source = "";
for (let index = 0; index < tokens.length; index++) {
    const token = tokens[index];
    const separator = index > 0 && !canJoin(tokens[index - 1], token) ? " " : "";
    source += separator + token.text;
}
source += "\n";

const verification = tokenize(source);
if (verification.length !== tokens.length
    || verification.some((token, index) => token.type !== tokens[index].type || token.text !== tokens[index].text)) {
    throw new Error("Token-preserving Luau compaction failed verification");
}

fs.writeFileSync(loaderPath, source, "utf8");
fs.writeFileSync(toolPath, source, "utf8");

const artifactBuffer = Buffer.from(source, "utf8");
const artifactIdentity = identity(artifactBuffer);
manifest.build = {
    generatedFromCommit: sourceCommit,
    sourceTree,
    embeddedRuntimeFingerprint: embeddedManifest.fingerprint,
    source: {
        path: manifest.suite.sourceEntry,
        version: manifest.suite.version,
        ...sourceIdentity,
    },
    artifacts: {
        loader: { path: "loader.lua", ...artifactIdentity },
        toolofmind: { path: "toolofmind.lua", ...artifactIdentity },
    },
};
fs.writeFileSync(manifestPath, JSON.stringify(manifest, null, 2) + "\n", "utf8");

process.stdout.write(
    `Generated PSX OG slim farm\n`
    + `  suite: ${manifest.suite.version}\n`
    + `  source commit: ${sourceCommit} (${sourceTree})\n`
    + `  source identity: ${sourceIdentity.bytes} bytes | sha256=${sourceIdentity.sha256} | djb2=${sourceIdentity.djb2}\n`
    + `  runtime manifest: sha256=${embeddedManifest.fingerprint.sha256} | djb2=${embeddedManifest.fingerprint.djb2}\n`
    + `  artifact: ${artifactIdentity.bytes} bytes | sha256=${artifactIdentity.sha256} | djb2=${artifactIdentity.djb2}\n`
    + `  features: pet farm, coordinated auto egg, dynamic New Year gold/rainbow/dark matter machines, dark matter auto-claim, adaptive boosts and Boost Bundle fallback, live route health, active balance rates, loot magnet, anti-AFK, persistent profile, potato mode, FPS cap, timer-gated automation\n`
    + `  dependencies: ${manifest.moduleOrder.length} pinned modules + WindUI ${manifest.windUI.version}\n`
);
