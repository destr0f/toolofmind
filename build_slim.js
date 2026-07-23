const fs = require("fs");
const path = require("path");

const root = __dirname;
const sourcePath = path.join(root, "slim_farm.lua");
const loaderPath = path.join(root, "loader.lua");
const toolPath = path.join(root, "toolofmind.lua");

const rawSource = fs.readFileSync(sourcePath, "utf8").replace(/^\uFEFF/, "");

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

const tokens = tokenize(rawSource);
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

process.stdout.write(
    `Generated PSX OG slim farm\n`
    + `  source: ${Buffer.byteLength(source, "utf8")} bytes\n`
    + `  features: pet farm, coordinated auto egg, dynamic New Year gold/rainbow/dark matter machines, dark matter auto-claim, adaptive boosts and Boost Bundle fallback, live route health, active balance rates, loot magnet, anti-AFK, persistent profile, potato mode, FPS cap, timer-gated automation\n`
    + `  external dependency: WindUI 1.6.64-fix\n`
);
