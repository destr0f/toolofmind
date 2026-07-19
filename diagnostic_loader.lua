local env = getgenv()
env.PSX_OG_TRACE_BOOT = true

local traceLines = {}
local function persist(name, text)
    pcall(function()
        if type(writefile) == "function" then
            writefile(name, tostring(text))
        end
    end)
end

local function trace(stage)
    local line = string.format("[%0.3f] %s", os.clock(), tostring(stage))
    table.insert(traceLines, line)
    persist("PSX_OG_loader_trace.txt", table.concat(traceLines, "\n"))
    print("[PSX LOADER] " .. tostring(stage))
end

trace("01 diagnostic loader entered")

local mainUrl = "https://raw.githubusercontent.com/destr0f/toolofmind/main/toolofmind.lua"
trace("02 main download started")
local downloaded, source = pcall(function()
    return game:HttpGet(mainUrl)
end)
if not downloaded then
    local message = "HttpGet failed: " .. tostring(source)
    persist("PSX_OG_loader_error.txt", message)
    error(message, 0)
end

trace("03 main downloaded, bytes=" .. tostring(#source))
local chunk, compileError = loadstring(source)
source = nil
if not chunk then
    local message = "Main compile failed: " .. tostring(compileError)
    persist("PSX_OG_loader_error.txt", message)
    error(message, 0)
end

trace("04 main compiled")
local function captureError(problem)
    local message = tostring(problem)
    if debug and type(debug.traceback) == "function" then
        local ok, traceback = pcall(debug.traceback, message, 2)
        if ok and traceback then message = traceback end
    end
    persist("PSX_OG_loader_error.txt", message)
    return message
end

local ok, result = xpcall(chunk, captureError)
chunk = nil
if not ok then
    warn("[PSX LOADER] Lua error captured:\n" .. tostring(result))
    error(result, 0)
end

trace("05 main returned without a Lua error")
return result
