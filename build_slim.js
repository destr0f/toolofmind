const fs = require("fs");
const path = require("path");

const root = __dirname;
const sourcePath = path.join(root, "slim_farm.lua");
const loaderPath = path.join(root, "loader.lua");
const toolPath = path.join(root, "toolofmind.lua");

const source = fs.readFileSync(sourcePath, "utf8")
    .replace(/^\uFEFF/, "")
    .split(/\r?\n/)
    .filter((line) => !/^\s*--/.test(line))
    .join("\n")
    .replace(/[ \t]+$/gm, "")
    .replace(/^[ \t]+/gm, "")
    .replace(/\n{2,}/g, "\n")
    .trim() + "\n";

fs.writeFileSync(loaderPath, source, "utf8");
fs.writeFileSync(toolPath, source, "utf8");

process.stdout.write(
    `Generated PSX OG slim farm\n`
    + `  source: ${Buffer.byteLength(source, "utf8")} bytes\n`
    + `  features: pet farm, loot magnet, anti-AFK, develop diamond-pack test\n`
    + `  external dependency: WindUI 1.6.64-fix\n`
);
