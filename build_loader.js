const crypto = require("crypto");
const fs = require("fs");
const path = require("path");

const root = __dirname;
const mainPath = path.join(root, "toolofmind.lua");
const windPath = path.join(root, "vendor", "WindUI-1.6.64-fix.lua");
const loaderPath = path.join(root, "loader.lua");

const mainVendorSource = fs.readFileSync(mainPath, "utf8").replace(/^\uFEFF/, "");
const mainSource = mainVendorSource
    .split(/\r?\n/)
    .filter((line) => !/^\s*--/.test(line))
    .join("\n")
    .replace(/[ \t]+$/gm, "")
    .replace(/\n{3,}/g, "\n\n");
const windVendorSource = fs.readFileSync(windPath, "utf8").replace(/^\uFEFF/, "");
const windSource = windVendorSource.replace(
    "if d:IsStudio()or not writefile then",
    "if true then -- standalone bundle: use the embedded icon pack"
);
if (windSource === windVendorSource) {
    throw new Error("WindUI icon-loader patch point was not found");
}

const mainBytes = Buffer.from(mainSource, "utf8");
const windBytes = Buffer.from(windSource, "utf8");
const mainVendorHash = crypto.createHash("sha256").update(mainVendorSource).digest("hex");
const mainHash = crypto.createHash("sha256").update(mainBytes).digest("hex");
const windVendorHash = crypto.createHash("sha256").update(windVendorSource).digest("hex");
const windHash = crypto.createHash("sha256").update(windBytes).digest("hex");

function hashAt(input, position) {
    return (((input[position] * 251 + input[position + 1]) * 251 + input[position + 2]) & 0xffff);
}

// Small deterministic LZSS format used only by the generated loader:
//   0xxxxxxx: literal run (token + 1 bytes)
//   1xxxxxxx: back-reference (token low bits + 3 bytes), then uint16 distance.
function compressLzss(input) {
    const head = new Int32Array(65536);
    const previous = new Int32Array(input.length);
    head.fill(-1);
    previous.fill(-1);

    const output = [];
    let literalStart = 0;
    let position = 0;

    function insert(index) {
        if (index + 2 >= input.length) return;
        const hash = hashAt(input, index);
        previous[index] = head[hash];
        head[hash] = index;
    }

    function flushLiterals(end) {
        let start = literalStart;
        while (start < end) {
            const length = Math.min(128, end - start);
            output.push(length - 1);
            for (let index = 0; index < length; index += 1) {
                output.push(input[start + index]);
            }
            start += length;
        }
    }

    while (position < input.length) {
        let bestLength = 0;
        let bestDistance = 0;

        if (position + 3 < input.length) {
            let candidate = head[hashAt(input, position)];
            const maximumLength = Math.min(130, input.length - position);
            let checked = 0;

            while (candidate >= 0 && checked < 192) {
                const distance = position - candidate;
                if (distance > 65535) break;

                let length = 0;
                while (
                    length < maximumLength
                    && input[candidate + length] === input[position + length]
                ) {
                    length += 1;
                }

                if (length > bestLength) {
                    bestLength = length;
                    bestDistance = distance;
                    if (length === maximumLength) break;
                }

                candidate = previous[candidate];
                checked += 1;
            }
        }

        if (bestLength >= 4) {
            flushLiterals(position);
            output.push(0x80 | (bestLength - 3));
            output.push(bestDistance & 0xff, (bestDistance >>> 8) & 0xff);

            const matchEnd = position + bestLength;
            while (position < matchEnd) {
                insert(position);
                position += 1;
            }
            literalStart = position;
        } else {
            insert(position);
            position += 1;
        }
    }

    flushLiterals(input.length);
    return Buffer.from(output);
}

function decompressLzssForVerification(input, expectedLength) {
    const output = Buffer.alloc(expectedLength);
    let inputPosition = 0;
    let outputPosition = 0;

    while (inputPosition < input.length) {
        const token = input[inputPosition++];
        if (token < 0x80) {
            const length = token + 1;
            input.copy(output, outputPosition, inputPosition, inputPosition + length);
            inputPosition += length;
            outputPosition += length;
        } else {
            const length = (token & 0x7f) + 3;
            const distance = input[inputPosition] | (input[inputPosition + 1] << 8);
            inputPosition += 2;
            const sourcePosition = outputPosition - distance;
            let available = distance;
            let remaining = length;
            while (remaining > 0) {
                const copyLength = Math.min(available, remaining);
                output.copy(
                    output,
                    outputPosition,
                    sourcePosition,
                    sourcePosition + copyLength
                );
                outputPosition += copyLength;
                remaining -= copyLength;
                available += copyLength;
            }
        }
    }

    if (outputPosition !== expectedLength) {
        throw new Error(`LZSS verification length mismatch: ${outputPosition} != ${expectedLength}`);
    }
    return output;
}

const BASE85_ALPHABET = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz!#$%&()*+,-./:;<=>?@^_`";
if (BASE85_ALPHABET.length !== 85) throw new Error("Base85 alphabet must contain 85 characters");

function encodeBase85(bufferValue, width = 160) {
    let encoded = "";
    for (let position = 0; position < bufferValue.length; position += 4) {
        let value = 0;
        for (let offset = 0; offset < 4; offset += 1) {
            value = value * 256 + (bufferValue[position + offset] || 0);
        }

        const digits = new Array(5);
        for (let index = 4; index >= 0; index -= 1) {
            digits[index] = BASE85_ALPHABET[value % 85];
            value = Math.floor(value / 85);
        }
        encoded += digits.join("");
    }

    const lines = [];
    for (let position = 0; position < encoded.length; position += width) {
        lines.push(encoded.slice(position, position + width));
    }
    return lines.join("\n");
}

function decodeBase85ForVerification(encoded, expectedLength) {
    const decode = new Map(Array.from(BASE85_ALPHABET, (character, index) => [character, index]));
    const output = Buffer.alloc(expectedLength);
    let accumulator = 0;
    let digitCount = 0;
    let outputPosition = 0;

    for (const character of encoded) {
        const value = decode.get(character);
        if (value === undefined) continue;
        accumulator = accumulator * 85 + value;
        digitCount += 1;

        if (digitCount === 5) {
            for (let shift = 3; shift >= 0 && outputPosition < expectedLength; shift -= 1) {
                output[outputPosition++] = Math.floor(accumulator / (256 ** shift)) % 256;
            }
            accumulator = 0;
            digitCount = 0;
        }
    }

    if (outputPosition !== expectedLength) {
        throw new Error(`Base85 verification length mismatch: ${outputPosition} != ${expectedLength}`);
    }
    return output;
}

function assertRoundTrip(name, original, compressed) {
    const restored = decompressLzssForVerification(compressed, original.length);
    if (!restored.equals(original)) {
        throw new Error(`${name} LZSS round-trip verification failed`);
    }
}

const MAIN_BLOCK_SIZE = 24 * 1024;
const mainBlocks = [];
for (let offset = 0; offset < mainBytes.length; offset += MAIN_BLOCK_SIZE) {
    const raw = mainBytes.subarray(offset, Math.min(offset + MAIN_BLOCK_SIZE, mainBytes.length));
    const compressed = compressLzss(raw);
    const payload = encodeBase85(compressed);
    const blockNumber = mainBlocks.length + 1;
    assertRoundTrip(`main block ${blockNumber}`, raw, compressed);
    if (!decodeBase85ForVerification(payload, compressed.length).equals(compressed)) {
        throw new Error(`Main block ${blockNumber} Base85 round-trip verification failed`);
    }
    mainBlocks.push({ raw, compressed, payload });
}

const windCompressed = compressLzss(windBytes);
assertRoundTrip("WindUI", windBytes, windCompressed);

const windPayload = encodeBase85(windCompressed);
if (!decodeBase85ForVerification(windPayload, windCompressed.length).equals(windCompressed)) {
    throw new Error("WindUI Base85 round-trip verification failed");
}

const mainPackedSize = mainBlocks.reduce((total, block) => total + block.compressed.length, 0);
const mainBlocksLua = mainBlocks.map((block, index) => String.raw`    {
        RawSize = ${block.raw.length},
        PackedSize = ${block.compressed.length},
        Data = [==[
${block.payload}
]==]
    }${index + 1 < mainBlocks.length ? "," : ""}`
).join("\n");

const loader = String.raw`-- AUTO-GENERATED by build_loader.js. Do not edit loader.lua directly.
-- PSX OG compressed standalone loader: one HTTP request, no runtime downloads.
-- Main source SHA256: ${mainVendorHash}
-- Main bundled SHA256: ${mainHash}
-- WindUI 1.6.64-fix vendor SHA256: ${windVendorHash}
-- WindUI bundled SHA256: ${windHash}

local __psxEnv = type(getgenv) == "function" and getgenv() or _G
local __PSX_LOADER_VERSION = "3.6.0"
local __PSX_TRACE_FILE = "PSX_OG_loader_trace.txt"
local __PSX_ERROR_FILE = "PSX_OG_loader_error.txt"
local __PSX_WIND_RAW_SIZE = ${windBytes.length}
local __PSX_WIND_PACKED_SIZE = ${windCompressed.length}
local __PSX_MAIN_RAW_SIZE = ${mainBytes.length}

local __psxWindPayload = [==[
${windPayload}
]==]

local __psxMainBlocks = {
${mainBlocksLua}
}

local __psxPreviousState = __psxEnv.PSX_OG_LOADER_STATE
if type(__psxPreviousState) == "table"
    and __psxPreviousState.Running == true
    and os.clock() - (tonumber(__psxPreviousState.StartedAt) or 0) < 60 then
    warn("[PSX LOADER] A loader run is already in progress: " .. tostring(__psxPreviousState.Phase))
    return __psxPreviousState
end

local __psxState = {
    Version = __PSX_LOADER_VERSION,
    Mode = "compressed-standalone",
    Running = true,
    Ready = false,
    Phase = "created",
    StartedAt = os.clock(),
    Trace = {}
}
__psxEnv.PSX_OG_LOADER_STATE = __psxState

local function __psxPersist(name, contents)
    pcall(function()
        if type(writefile) == "function" then
            writefile(name, tostring(contents or ""))
        end
    end)
end

local function __psxTrace(phase, detail)
    __psxState.Phase = phase
    local suffix = detail ~= nil and (" | " .. tostring(detail)) or ""
    local line = string.format("[%0.3f] %s%s", os.clock(), tostring(phase), suffix)
    table.insert(__psxState.Trace, line)
    __psxPersist(__PSX_TRACE_FILE, table.concat(__psxState.Trace, "\n"))
    print("[PSX LOADER] " .. tostring(phase) .. suffix)
end

local function __psxCaptureError(problem)
    local message = tostring(problem)
    if debug and type(debug.traceback) == "function" then
        local success, traceback = pcall(debug.traceback, message, 2)
        if success and traceback then message = traceback end
    end
    __psxState.Error = message
    __psxState.Phase = "failed"
    __psxState.Running = false
    __psxPersist(__PSX_ERROR_FILE, message)
    return message
end

local function __psxWaitForGameReady()
    __psxTrace("01 waiting for game")
    local loaded = false
    pcall(function() loaded = game:IsLoaded() end)
    if not loaded then game.Loaded:Wait() end

    local Players = game:GetService("Players")
    local ReplicatedStorage = game:GetService("ReplicatedStorage")
    local RunService = game:GetService("RunService")
    local deadline = os.clock() + 30
    local player = Players.LocalPlayer
    while not player and os.clock() < deadline do
        task.wait(0.05)
        player = Players.LocalPlayer
    end
    if not player then error("LocalPlayer did not appear within 30 seconds", 0) end

    local playerScripts = player:FindFirstChild("PlayerScripts")
        or player:WaitForChild("PlayerScripts", 20)
    if not playerScripts then error("PlayerScripts did not load", 0) end

    local framework = ReplicatedStorage:FindFirstChild("Framework")
        or ReplicatedStorage:WaitForChild("Framework", 20)
    local library = framework and (
        framework:FindFirstChild("Library")
        or framework:WaitForChild("Library", 20)
    )
    if not library then error("ReplicatedStorage.Framework.Library did not load", 0) end

    for _ = 1, 3 do RunService.Heartbeat:Wait() end
    __psxTrace("02 game ready", "place=" .. tostring(game.PlaceId))
end

local function __psxDecodeBase85(data, expectedLength)
    if type(buffer) ~= "table" or type(buffer.create) ~= "function" then
        error("This loader requires the Roblox buffer library", 0)
    end

    local alphabet = "${BASE85_ALPHABET}"
    local decode = {}
    for index = 1, #alphabet do
        decode[string.byte(alphabet, index)] = index - 1
    end

    local output = buffer.create(expectedLength)
    local outputPosition = 0
    local accumulator = 0
    local digitCount = 0
    local nextYield = 32768

    for index = 1, #data do
        local value = decode[string.byte(data, index)]
        if value ~= nil then
            accumulator = accumulator * 85 + value
            digitCount = digitCount + 1
            if digitCount == 5 then
                for shift = 3, 0, -1 do
                    if outputPosition < expectedLength then
                        local divisor = 256 ^ shift
                        buffer.writeu8(
                            output,
                            outputPosition,
                            math.floor(accumulator / divisor) % 256
                        )
                        outputPosition = outputPosition + 1
                    end
                end
                accumulator = 0
                digitCount = 0
            end
        end

        if index >= nextYield then
            task.wait()
            nextYield = index + 32768
        end
    end

    if outputPosition ~= expectedLength then
        error(
            "Base85 length mismatch: " .. tostring(outputPosition)
            .. " != " .. tostring(expectedLength),
            0
        )
    end
    return output
end

local function __psxDecompressLzss(input, inputLength, expectedLength, progressPhase, returnBuffer)
    local output = buffer.create(expectedLength)
    local inputPosition = 0
    local outputPosition = 0
    local nextYield = 16384

    while inputPosition < inputLength do
        local token = buffer.readu8(input, inputPosition)
        inputPosition = inputPosition + 1

        if token < 128 then
            local length = token + 1
            if inputPosition + length > inputLength or outputPosition + length > expectedLength then
                error("Invalid literal run in compressed payload", 0)
            end
            buffer.copy(output, outputPosition, input, inputPosition, length)
            inputPosition = inputPosition + length
            outputPosition = outputPosition + length
        else
            local length = (token - 128) + 3
            if inputPosition + 2 > inputLength then
                error("Truncated back-reference in compressed payload", 0)
            end
            local distance = buffer.readu8(input, inputPosition)
                + buffer.readu8(input, inputPosition + 1) * 256
            inputPosition = inputPosition + 2
            if distance < 1 or distance > outputPosition or outputPosition + length > expectedLength then
                error("Invalid back-reference in compressed payload", 0)
            end

            local sourcePosition = outputPosition - distance
            local available = distance
            local remaining = length
            while remaining > 0 do
                local copyLength = math.min(available, remaining)
                buffer.copy(output, outputPosition, output, sourcePosition, copyLength)
                outputPosition = outputPosition + copyLength
                remaining = remaining - copyLength
                available = available + copyLength
            end
        end

        if outputPosition >= nextYield then
            if progressPhase then
                __psxTrace(
                    progressPhase,
                    tostring(outputPosition) .. "/" .. tostring(expectedLength)
                )
            end
            task.wait()
            nextYield = outputPosition + 16384
        end
    end

    if outputPosition ~= expectedLength then
        error(
            "LZSS length mismatch: " .. tostring(outputPosition)
            .. " != " .. tostring(expectedLength),
            0
        )
    end
    if returnBuffer then return output end
    return buffer.tostring(output)
end

__psxEnv.PSX_OG_TRACE_BOOT = true
__psxEnv.PSX_OG_SAFE_BOOT = true
__psxEnv.PSX_OG_SAFE_BOOT_DELAY = math.clamp(
    tonumber(__psxEnv.PSX_OG_SAFE_BOOT_DELAY) or 0.03,
    0.01,
    0.25
)

__psxState.Phase = "scheduled"
__psxTrace(
    "00 compressed loader entered",
    "version=" .. __PSX_LOADER_VERSION .. " | bytes=${mainPackedSize + windCompressed.length}"
)

task.defer(function()
    task.wait(0.15)

    local success, problem = xpcall(function()
        __psxWaitForGameReady()

        local mainBlockCount = #__psxMainBlocks
        local mainBuffer = buffer.create(__PSX_MAIN_RAW_SIZE)
        local mainOffset = 0
        __psxTrace("03 staged main decode", "blocks=" .. tostring(mainBlockCount))

        for index, block in ipairs(__psxMainBlocks) do
            __psxTrace(
                "04 main block",
                tostring(index) .. "/" .. tostring(mainBlockCount)
                .. " | decoding=" .. tostring(block.PackedSize)
            )
            local mainPacked = __psxDecodeBase85(block.Data, block.PackedSize)
            block.Data = nil

            __psxTrace(
                "04 main block",
                tostring(index) .. "/" .. tostring(mainBlockCount)
                .. " | decompressing=" .. tostring(block.RawSize)
            )
            local mainBlockBuffer = __psxDecompressLzss(
                mainPacked,
                block.PackedSize,
                block.RawSize,
                "04 main block " .. tostring(index) .. " progress",
                true
            )
            mainPacked = nil

            __psxTrace(
                "04 main block",
                tostring(index) .. "/" .. tostring(mainBlockCount) .. " | decompressed"
            )
            buffer.copy(mainBuffer, mainOffset, mainBlockBuffer, 0, block.RawSize)
            mainOffset = mainOffset + block.RawSize
            mainBlockBuffer = nil
            __psxTrace(
                "04 main block",
                tostring(index) .. "/" .. tostring(mainBlockCount)
                .. " | copied | total=" .. tostring(mainOffset)
            )
            if index < mainBlockCount then
                task.wait(0.08)
            end
        end

        __psxMainBlocks = nil
        if mainOffset ~= __PSX_MAIN_RAW_SIZE then
            error(
                "Main assembly length mismatch: " .. tostring(mainOffset)
                .. " != " .. tostring(__PSX_MAIN_RAW_SIZE),
                0
            )
        end

        __psxTrace("05 main buffer complete", "bytes=" .. tostring(mainOffset))
        __psxTrace("06 creating main source")
        local mainSource = buffer.tostring(mainBuffer)
        mainBuffer = nil
        __psxTrace("07 main source ready", "bytes=" .. tostring(#mainSource))
        __psxTrace("08 compiling main")
        local mainChunk, mainError = loadstring(mainSource)
        mainSource = nil
        if not mainChunk then error("Main compile failed: " .. tostring(mainError), 0) end
        __psxTrace("09 main chunk ready")
        __psxTrace("10 decoding WindUI payload")
        local windPacked = __psxDecodeBase85(__psxWindPayload, __PSX_WIND_PACKED_SIZE)
        __psxWindPayload = nil
        __psxTrace("11 decompressing WindUI", "raw=" .. tostring(__PSX_WIND_RAW_SIZE))
        local windSource = __psxDecompressLzss(
            windPacked,
            __PSX_WIND_PACKED_SIZE,
            __PSX_WIND_RAW_SIZE,
            "11 WindUI progress"
        )
        windPacked = nil

        __psxTrace("12 compiling WindUI")
        local windChunk, windError = loadstring(windSource)
        windSource = nil
        if not windChunk then error("WindUI compile failed: " .. tostring(windError), 0) end
        __psxEnv.PSX_OG_BUNDLED_WINDUI_CHUNK = windChunk
        windChunk = nil
        __psxTrace("13 WindUI chunk ready")

        game:GetService("RunService").Heartbeat:Wait()
        task.wait(0.1)
        __psxTrace("14 executing main")
        __psxState.Result = mainChunk()
        mainChunk = nil

        __psxState.Running = false
        __psxState.Ready = true
        __psxState.FinishedAt = os.clock()
        __psxTrace(
            "15 main ready",
            string.format("%.2fs", __psxState.FinishedAt - __psxState.StartedAt)
        )
    end, __psxCaptureError)

    if not success then
        __psxEnv.PSX_OG_BUNDLED_WINDUI_CHUNK = nil
        warn("[PSX LOADER] Startup failed:\n" .. tostring(problem))
    end
end)

return __psxState
`;

fs.writeFileSync(loaderPath, loader, "utf8");
process.stdout.write(
    `Generated compressed loader.lua (${Buffer.byteLength(loader, "utf8")} bytes)\n`
    + `  WindUI: ${windBytes.length} -> ${windCompressed.length} bytes\n`
    + `  Main:   ${mainBytes.length} -> ${mainPackedSize} bytes in ${mainBlocks.length} blocks\n`
);
