const crypto = require("crypto");
const fs = require("fs");
const path = require("path");

const root = __dirname;
const mainPath = path.join(root, "toolofmind.lua");
const windPath = path.join(root, "vendor", "WindUI-1.6.64-fix.lua");
const loaderPath = path.join(root, "loader.lua");
const payloadDirectory = path.join(root, "payload");

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
    "if true then -- staged bundle: use the embedded icon pack"
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
            for (let index = 0; index < length; index += 1) output.push(input[start + index]);
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

function decompressForVerification(input, expectedLength) {
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
                output.copy(output, outputPosition, sourcePosition, sourcePosition + copyLength);
                outputPosition += copyLength;
                remaining -= copyLength;
                available += copyLength;
            }
        }
    }
    if (outputPosition !== expectedLength) {
        throw new Error(`LZSS length mismatch: ${outputPosition} != ${expectedLength}`);
    }
    return output;
}

const BASE85_ALPHABET = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz!#$%&()*+,-./:;<=>?@^_`";
if (BASE85_ALPHABET.length !== 85) throw new Error("Base85 alphabet must contain 85 characters");

function encodeBase85(value, width = 160) {
    let encoded = "";
    for (let position = 0; position < value.length; position += 4) {
        let accumulator = 0;
        for (let offset = 0; offset < 4; offset += 1) {
            accumulator = accumulator * 256 + (value[position + offset] || 0);
        }
        const digits = new Array(5);
        for (let index = 4; index >= 0; index -= 1) {
            digits[index] = BASE85_ALPHABET[accumulator % 85];
            accumulator = Math.floor(accumulator / 85);
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
        throw new Error(`Base85 length mismatch: ${outputPosition} != ${expectedLength}`);
    }
    return output;
}

const PACKED_PART_SIZE = 8 * 1024;
fs.mkdirSync(payloadDirectory, { recursive: true });

function buildPayload(kind, original, hash) {
    const compressed = compressLzss(original);
    if (!decompressForVerification(compressed, original.length).equals(original)) {
        throw new Error(`${kind} LZSS round-trip failed`);
    }
    const parts = [];
    for (let offset = 0; offset < compressed.length; offset += PACKED_PART_SIZE) {
        const packed = compressed.subarray(offset, Math.min(offset + PACKED_PART_SIZE, compressed.length));
        const encoded = encodeBase85(packed);
        const number = parts.length + 1;
        if (!decodeBase85ForVerification(encoded, packed.length).equals(packed)) {
            throw new Error(`${kind} part ${number} Base85 round-trip failed`);
        }
        const fileName = `${kind.toLowerCase()}-${hash.slice(0, 20)}-${String(number).padStart(2, "0")}.psx`;
        fs.writeFileSync(path.join(payloadDirectory, fileName), `${encoded}\n`, "utf8");
        parts.push({
            fileName,
            packedSize: packed.length,
            encodedChars: Math.ceil(packed.length / 4) * 5,
        });
    }
    return { compressed, parts };
}

function manifestToLua(parts) {
    return parts.map((part, index) => String.raw`    {
        File = ${JSON.stringify(part.fileName)},
        PackedSize = ${part.packedSize},
        EncodedChars = ${part.encodedChars}
    }${index + 1 < parts.length ? "," : ""}`).join("\n");
}

const mainPayload = buildPayload("Main", mainBytes, mainHash);
const windPayload = buildPayload("Wind", windBytes, windHash);
const mainManifest = manifestToLua(mainPayload.parts);
const windManifest = manifestToLua(windPayload.parts);

const loaderTemplate = String.raw`-- AUTO-GENERATED by build_staged_loader.js.
-- Main source SHA256: ${mainVendorHash}
-- Main bundled SHA256: ${mainHash}
-- WindUI vendor SHA256: ${windVendorHash}
-- WindUI bundled SHA256: ${windHash}

local env=type(getgenv)=="function"and getgenv()or _G
local VERSION="4.0.0"
local BASE=tostring(env.PSX_OG_PAYLOAD_BASE_URL or"https://raw.githubusercontent.com/destr0f/toolofmind/main/payload/")
local MAIN_RAW=${mainBytes.length}
local MAIN_PACKED=${mainPayload.compressed.length}
local WIND_RAW=${windBytes.length}
local WIND_PACKED=${windPayload.compressed.length}
local MAIN_PARTS={
${mainManifest}
}
local WIND_PARTS={
${windManifest}
}

local old=env.PSX_OG_LOADER_STATE
if type(old)=="table"then old.Running=false old.Superseded=true end
local state={Version=VERSION,Mode="staged-cache",Running=true,Ready=false,Phase="created",StartedAt=os.clock(),Trace={}}
env.PSX_OG_LOADER_STATE=state

local function persist(name,value)
 pcall(function()if type(writefile)=="function"then writefile(name,tostring(value or""))end end)
end
local function trace(phase,detail)
 state.Phase=phase
 local suffix=detail~=nil and(" | "..tostring(detail))or""
 table.insert(state.Trace,string.format("[%0.3f] %s%s",os.clock(),phase,suffix))
 print("[PSX LOADER] "..phase..suffix)
end
local function capture(problem)
 local message=tostring(problem)
 if debug and type(debug.traceback)=="function"then
  local ok,value=pcall(debug.traceback,message,2)
  if ok and value then message=value end
 end
 state.Error=message state.Phase="failed"state.Running=false
 persist("PSX_OG_loader_error.txt",table.concat(state.Trace,"\n").."\n\n"..message)
 return message
end
local function checkReady()
 trace("01 checking game")
 local players=game:GetService("Players")
 local storage=game:GetService("ReplicatedStorage")
 local player=players.LocalPlayer
 local framework=storage:FindFirstChild("Framework")
 if not player or not player:FindFirstChild("PlayerScripts")then error("PlayerScripts is not ready; run again",0)end
 if not framework or not framework:FindFirstChild("Library")then error("Framework.Library is not ready; run again",0)end
 trace("02 game ready","place="..tostring(game.PlaceId))
end
local function cacheName(part)return"PSX_OG_payload_"..part.File end
local function valid(data,part)
 return type(data)=="string"and#data>=part.EncodedChars and not string.find(data,"<!DOCTYPE html",1,true)
end
local function readCache(part)
 if type(readfile)~="function"then return nil end
 local ok,data=pcall(readfile,cacheName(part))
 if ok and valid(data,part)then return data end
 return nil
end
local function cachePart(part,index,total,kind)
 local data=readCache(part)
 if data then trace("03 payload cached",kind.." "..index.."/"..total)return end
 trace("03 payload download",kind.." "..index.."/"..total)
 local ok,response=pcall(function()return game:HttpGet(BASE..part.File)end)
 if not ok then error("Payload download failed: "..tostring(response),0)end
 if not valid(response,part)then error("Invalid payload response: "..part.File,0)end
 writefile(cacheName(part),response)
 trace("03 payload saved",kind.." "..index.."/"..total)
end
local function prepare(parts,kind)
 for index,part in ipairs(parts)do
  if env.PSX_OG_LOADER_STATE~=state then error("Loader superseded",0)end
  cachePart(part,index,#parts,kind)
 end
end

local alphabet="${BASE85_ALPHABET}"
local decode={}
for index=1,#alphabet do decode[string.byte(alphabet,index)]=index-1 end
local function decodeInto(data,output,offset,expected)
 local position,accumulator,digits=0,0,0
 for index=1,#data do
  local value=decode[string.byte(data,index)]
  if value~=nil then
   accumulator=accumulator*85+value digits=digits+1
   if digits==5 then
    for shift=3,0,-1 do
     if position<expected then
      buffer.writeu8(output,offset+position,math.floor(accumulator/(256^shift))%256)
      position=position+1
     end
    end
    accumulator=0 digits=0
   end
  end
 end
 if position~=expected then error("Base85 cached payload length mismatch",0)end
end
local function readPacked(parts,size,kind)
 local output=buffer.create(size)
 local offset=0
 for index,part in ipairs(parts)do
  trace("04 payload decode",kind.." "..index.."/"..#parts)
  local data=readCache(part)
  if not data then error("Cached payload missing: "..part.File,0)end
  decodeInto(data,output,offset,part.PackedSize)
  data=nil offset=offset+part.PackedSize
 end
 if offset~=size then error("Packed payload size mismatch",0)end
 return output
end
local function decompress(input,inputLength,expected)
 local output=buffer.create(expected)
 local inputPosition,outputPosition=0,0
 while inputPosition<inputLength do
  local token=buffer.readu8(input,inputPosition)inputPosition=inputPosition+1
  if token<128 then
   local length=token+1
   if inputPosition+length>inputLength or outputPosition+length>expected then error("Invalid literal run",0)end
   buffer.copy(output,outputPosition,input,inputPosition,length)
   inputPosition=inputPosition+length outputPosition=outputPosition+length
  else
   local length=token-128+3
   if inputPosition+2>inputLength then error("Truncated back-reference",0)end
   local distance=buffer.readu8(input,inputPosition)+buffer.readu8(input,inputPosition+1)*256
   inputPosition=inputPosition+2
   if distance<1 or distance>outputPosition or outputPosition+length>expected then error("Invalid back-reference",0)end
   local source=outputPosition-distance
   local available,remaining=distance,length
   while remaining>0 do
    local count=math.min(available,remaining)
    buffer.copy(output,outputPosition,output,source,count)
    outputPosition=outputPosition+count remaining=remaining-count available=available+count
   end
  end
 end
 if outputPosition~=expected then error("LZSS output size mismatch",0)end
 return output
end
local function compilePayload(parts,packedSize,rawSize,kind)
 trace("05 assembling",kind)
 local packed=readPacked(parts,packedSize,kind)
 trace("06 decompressing",kind.." | raw="..rawSize)
 local raw=decompress(packed,packedSize,rawSize)packed=nil
 trace("07 creating source",kind)
 local source=buffer.tostring(raw)raw=nil
 trace("08 compiling",kind.." | bytes="..#source)
 local chunk,problem=loadstring(source)source=nil
 if not chunk then error(kind.." compile failed: "..tostring(problem),0)end
 trace("09 compiled",kind)
 return chunk
end
local function run()
 checkReady()
 if type(buffer)~="table"or type(buffer.create)~="function"then error("Roblox buffer library required",0)end
 if type(readfile)~="function"or type(writefile)~="function"then error("readfile/writefile required",0)end
 env.PSX_OG_TRACE_BOOT=true env.PSX_OG_SAFE_BOOT=true
 env.PSX_OG_SAFE_BOOT_DELAY=math.clamp(tonumber(env.PSX_OG_SAFE_BOOT_DELAY)or.03,.01,.25)
 trace("03 preparing payload cache","parts="..tostring(#MAIN_PARTS+#WIND_PARTS))
 prepare(MAIN_PARTS,"Main")prepare(WIND_PARTS,"WindUI")
 trace("03 payload cache ready")
 local mainChunk=compilePayload(MAIN_PARTS,MAIN_PACKED,MAIN_RAW,"Main")MAIN_PARTS=nil
 local windChunk=compilePayload(WIND_PARTS,WIND_PACKED,WIND_RAW,"WindUI")WIND_PARTS=nil
 env.PSX_OG_BUNDLED_WINDUI_CHUNK=windChunk windChunk=nil
 state.Running=false state.Ready=true state.FinishedAt=os.clock()
 task.defer(mainChunk)mainChunk=nil
 trace("10 main queued; staged loader releasing",string.format("%.2fs",state.FinishedAt-state.StartedAt))
 persist("PSX_OG_loader_trace.txt",table.concat(state.Trace,"\n"))
end
local function worker()
 task.wait(.15)
 trace("00 worker started")
 local ok,problem=xpcall(run,capture)
 if not ok then env.PSX_OG_BUNDLED_WINDUI_CHUNK=nil warn("[PSX LOADER] Startup failed:\n"..tostring(problem))end
end
trace("00 staged loader entered","version="..VERSION.." | source-bytes=__SOURCE_BYTES__")
state.Phase="queued"
task.defer(worker)
return state
`;

let loader = loaderTemplate;
for (let pass = 0; pass < 3; pass += 1) {
    loader = loaderTemplate.replace("__SOURCE_BYTES__", String(Buffer.byteLength(loader, "utf8")));
}
fs.writeFileSync(loaderPath, loader, "utf8");
process.stdout.write(
    `Generated staged loader.lua (${Buffer.byteLength(loader, "utf8")} bytes)\n`
    + `  Main:   ${mainBytes.length} -> ${mainPayload.compressed.length} bytes in ${mainPayload.parts.length} parts\n`
    + `  WindUI: ${windBytes.length} -> ${windPayload.compressed.length} bytes in ${windPayload.parts.length} parts\n`
);
