const crypto = require("crypto");
const fs = require("fs");
const path = require("path");

const root = __dirname;
const mainPath = path.join(root, "toolofmind.lua");
const windPath = path.join(root, "vendor", "WindUI-1.6.64-fix.lua");
const loaderPath = path.join(root, "loader.lua");
const payloadDirectory = path.join(root, "payload");

// Filled after the payload commit is published. A commit-pinned jsDelivr URL
// avoids mutable branch caches and raw.githubusercontent request behaviour.
const PAYLOAD_COMMIT = null;

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
    "if true then -- binary bundle: use the embedded icon pack"
);
if (windSource === windVendorSource) throw new Error("WindUI patch point was not found");

const mainBytes = Buffer.from(mainSource, "utf8");
const windBytes = Buffer.from(windSource, "utf8");
const mainVendorHash = crypto.createHash("sha256").update(mainVendorSource).digest("hex");
const mainHash = crypto.createHash("sha256").update(mainBytes).digest("hex");
const windVendorHash = crypto.createHash("sha256").update(windVendorSource).digest("hex");
const windHash = crypto.createHash("sha256").update(windBytes).digest("hex");

function sha256(value) {
    return crypto.createHash("sha256").update(value).digest("hex");
}

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
            const end = position + bestLength;
            while (position < end) {
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
            const source = outputPosition - distance;
            let available = distance;
            let remaining = length;
            while (remaining > 0) {
                const count = Math.min(available, remaining);
                output.copy(output, outputPosition, source, source + count);
                outputPosition += count;
                remaining -= count;
                available += count;
            }
        }
    }
    if (outputPosition !== expectedLength) {
        throw new Error(`LZSS length mismatch: ${outputPosition} != ${expectedLength}`);
    }
    return output;
}

fs.mkdirSync(payloadDirectory, { recursive: true });
const mainPacked = compressLzss(mainBytes);
const windPacked = compressLzss(windBytes);
if (!decompressForVerification(mainPacked, mainBytes.length).equals(mainBytes)) {
    throw new Error("Main LZSS round-trip failed");
}
if (!decompressForVerification(windPacked, windBytes.length).equals(windBytes)) {
    throw new Error("WindUI LZSS round-trip failed");
}

function writePayloadParts(kind, sourceHash, packed, partSize) {
    const parts = [];
    for (let offset = 0; offset < packed.length; offset += partSize) {
        const data = packed.subarray(offset, Math.min(offset + partSize, packed.length));
        const number = parts.length + 1;
        const fileName = parts.length === 0 && data.length === packed.length
            ? `${kind}-${sourceHash.slice(0, 20)}-${sha256(data).slice(0, 12)}.bin`
            : `${kind}-${sourceHash.slice(0, 20)}-${String(number).padStart(2, "0")}-${sha256(data).slice(0, 12)}.bin`;
        fs.writeFileSync(path.join(payloadDirectory, fileName), data);
        parts.push({ fileName, size: data.length });
    }
    return parts;
}

function partsToLua(parts) {
    return parts.map((part, index) => (
        `{File=${JSON.stringify(part.fileName)},Size=${part.size}}${index + 1 < parts.length ? "," : ""}`
    )).join("");
}

const mainParts = writePayloadParts("main", mainHash, mainPacked, mainPacked.length);
const windParts = writePayloadParts("wind", windHash, windPacked, 24 * 1024);

const defaultBase = PAYLOAD_COMMIT
    ? `https://cdn.jsdelivr.net/gh/destr0f/toolofmind@${PAYLOAD_COMMIT}/payload/`
    : "https://raw.githubusercontent.com/destr0f/toolofmind/main/payload/";
const version = PAYLOAD_COMMIT ? "4.1.1" : "4.1.1-payload";

const loaderTemplate = String.raw`-- AUTO-GENERATED by build_binary_loader.js.
-- Main source SHA256: ${mainVendorHash}
-- Main bundled SHA256: ${mainHash}
-- WindUI vendor SHA256: ${windVendorHash}
-- WindUI bundled SHA256: ${windHash}

local env=type(getgenv)=="function"and getgenv()or _G
local VERSION=${JSON.stringify(version)}
local BASE=tostring(env.PSX_OG_PAYLOAD_BASE_URL or ${JSON.stringify(defaultBase)})
local MAIN={Parts={${partsToLua(mainParts)}},Packed=${mainPacked.length},Raw=${mainBytes.length}}
local WIND={Parts={${partsToLua(windParts)}},Packed=${windPacked.length},Raw=${windBytes.length}}

local old=env.PSX_OG_LOADER_STATE
if type(old)=="table"then old.Running=false old.Superseded=true end
local state={Version=VERSION,Mode="binary-cache",Running=true,Ready=false,Phase="created",StartedAt=os.clock(),Trace={}}
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
local function readCache(part)
 local ok,data=pcall(readfile,cacheName(part))
 if ok and type(data)=="string"and#data==part.Size then return data end
 return nil
end
local function cachePayload(item,kind)
 for index,part in ipairs(item.Parts)do
  local label=kind.." "..index.."/"..#item.Parts
  local data=readCache(part)
  if data then
   trace("03 binary cached",label.." | bytes="..#data)
  else
   trace("03 binary download",label.." | expected="..part.Size)
   local ok,response=pcall(function()return game:HttpGet(BASE..part.File)end)
   if not ok then error(label.." download failed: "..tostring(response),0)end
   trace("03 binary received",label.." | bytes="..tostring(type(response)=="string"and#response or 0))
   if type(response)~="string"or#response~=part.Size then error(label.." binary size mismatch",0)end
   trace("03 binary writing",label)
   local wrote,writeError=pcall(writefile,cacheName(part),response)
   if not wrote then error(label.." cache write failed: "..tostring(writeError),0)end
   trace("03 binary saved",label)
  end
  data=nil
  if index<#item.Parts then task.wait(.15)end
 end
end
local function toBuffer(data)
 if type(buffer.fromstring)=="function"then return buffer.fromstring(data)end
 local output=buffer.create(#data)
 if type(buffer.writestring)~="function"then error("buffer.fromstring or buffer.writestring required",0)end
 buffer.writestring(output,0,data)
 return output
end
local function readPacked(item,kind)
 local output=buffer.create(item.Packed)
 local offset=0
 for index,part in ipairs(item.Parts)do
  trace("04 binary reading",kind.." "..index.."/"..#item.Parts)
  local data=readCache(part)
  if not data then error(kind.." binary cache missing: "..part.File,0)end
  local source=toBuffer(data)data=nil
  buffer.copy(output,offset,source,0,part.Size)
  source=nil offset=offset+part.Size
 end
 if offset~=item.Packed then error(kind.." assembled binary size mismatch",0)end
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
local function compilePayload(item,kind)
 local packed=readPacked(item,kind)
 trace("05 decompressing",kind.." | raw="..item.Raw)
 local raw=decompress(packed,item.Packed,item.Raw)packed=nil
 trace("06 creating source",kind)
 local source=buffer.tostring(raw)raw=nil
 trace("07 compiling",kind.." | bytes="..#source)
 local chunk,problem=loadstring(source)source=nil
 if not chunk then error(kind.." compile failed: "..tostring(problem),0)end
 trace("08 compiled",kind)
 return chunk
end
local function run()
 checkReady()
 if type(buffer)~="table"or type(buffer.create)~="function"then error("Roblox buffer library required",0)end
 if type(readfile)~="function"or type(writefile)~="function"then error("readfile/writefile required",0)end
 env.PSX_OG_TRACE_BOOT=true env.PSX_OG_SAFE_BOOT=true
 env.PSX_OG_SAFE_BOOT_DELAY=math.clamp(tonumber(env.PSX_OG_SAFE_BOOT_DELAY)or.03,.01,.25)
 trace("03 preparing binary cache","requests="..tostring(#MAIN.Parts+#WIND.Parts))
 cachePayload(MAIN,"Main")
 task.wait(.2)
 cachePayload(WIND,"WindUI")
 trace("03 binary cache ready")
 local mainChunk=compilePayload(MAIN,"Main")MAIN=nil
 local windChunk=compilePayload(WIND,"WindUI")WIND=nil
 env.PSX_OG_BUNDLED_WINDUI_CHUNK=windChunk windChunk=nil
 state.Running=false state.Ready=true state.FinishedAt=os.clock()
 task.defer(mainChunk)mainChunk=nil
 trace("09 main queued; binary loader releasing",string.format("%.2fs",state.FinishedAt-state.StartedAt))
 persist("PSX_OG_loader_trace.txt",table.concat(state.Trace,"\n"))
end
local function worker()
 task.wait(.15)
 trace("00 worker started")
 local ok,problem=xpcall(run,capture)
 if not ok then env.PSX_OG_BUNDLED_WINDUI_CHUNK=nil warn("[PSX LOADER] Startup failed:\n"..tostring(problem))end
end
trace("00 binary loader entered","version="..VERSION.." | source-bytes=__SOURCE_BYTES__")
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
    `Generated binary loader.lua (${Buffer.byteLength(loader, "utf8")} bytes)\n`
    + `  Main:   ${mainBytes.length} -> ${mainPacked.length} bytes in ${mainParts.length} part(s)\n`
    + `  WindUI: ${windBytes.length} -> ${windPacked.length} bytes in ${windParts.length} part(s)\n`
    + `  Payload base: ${defaultBase}\n`
);
