-- PSX OG production loader
-- Keeps the downloaded source out of the main chunk's execution stack and
-- deliberately paces heavy UI startup stages through PSX_OG_SAFE_BOOT.

local env = type(getgenv) == "function" and getgenv() or _G
local LOADER_VERSION = "1.2.0"
local DEFAULT_MAIN_URL = "https://raw.githubusercontent.com/destr0f/toolofmind/main/toolofmind.lua"
local TRACE_FILE = "PSX_OG_loader_trace.txt"
local ERROR_FILE = "PSX_OG_loader_error.txt"

local previousState = env.PSX_OG_LOADER_STATE
if type(previousState) == "table"
    and previousState.Running == true
    and os.clock() - (tonumber(previousState.StartedAt) or 0) < 60 then
    warn("[PSX LOADER] A loader run is already in progress: " .. tostring(previousState.Phase))
    return previousState
end

local state = {
    Version = LOADER_VERSION,
    Running = true,
    Ready = false,
    Phase = "created",
    StartedAt = os.clock(),
    Trace = {}
}
env.PSX_OG_LOADER_STATE = state

local function persist(name, contents)
    pcall(function()
        if type(writefile) == "function" then
            writefile(name, tostring(contents or ""))
        end
    end)
end

local function trace(phase, detail)
    state.Phase = phase
    local suffix = detail ~= nil and (" | " .. tostring(detail)) or ""
    local line = string.format("[%0.3f] %s%s", os.clock(), tostring(phase), suffix)
    table.insert(state.Trace, line)
    persist(TRACE_FILE, table.concat(state.Trace, "\n"))
    print("[PSX LOADER] " .. tostring(phase) .. suffix)
end

local function captureError(problem)
    local message = tostring(problem)
    if debug and type(debug.traceback) == "function" then
        local success, traceback = pcall(debug.traceback, message, 2)
        if success and traceback then message = traceback end
    end
    state.Error = message
    state.Phase = "failed"
    state.Running = false
    persist(ERROR_FILE, message)
    return message
end

local function waitForGameReady()
    trace("01 waiting for game")
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
    trace("02 game ready", "place=" .. tostring(game.PlaceId))
end

local function readField(container, key)
    if type(container) ~= "table" then return nil end
    local success, value = pcall(function()
        return rawget(container, key)
    end)
    return success and value or nil
end

local function resolveRequestTransport()
    local candidates = {}
    local seen = {}

    local function add(label, candidate)
        if type(candidate) == "function" and not seen[candidate] then
            seen[candidate] = true
            table.insert(candidates, {
                Label = label,
                Call = candidate
            })
        end
    end

    add("PSX_OG_REQUEST", readField(env, "PSX_OG_REQUEST"))
    add("request", readField(env, "request"))
    add("http_request", readField(env, "http_request"))
    add("httprequest", readField(env, "httprequest"))
    add("_G.request", readField(_G, "request"))
    add("_G.http_request", readField(_G, "http_request"))

    for _, entry in ipairs({
        { "syn.request", "syn" },
        { "http.request", "http" },
        { "fluxus.request", "fluxus" },
        { "krnl.request", "krnl" }
    }) do
        local owner = readField(env, entry[2]) or readField(_G, entry[2])
        add(entry[1], readField(owner, "request"))
    end

    return candidates[1], #candidates
end

local function unpackResponse(response)
    if type(response) == "string" then
        return response, 200
    end
    if type(response) ~= "table" then
        return nil, nil
    end

    local body = response.Body
        or response.body
        or response.ResponseBody
        or response.responseBody
    local status = tonumber(
        response.StatusCode
        or response.Status
        or response.status
        or response.status_code
    )
    return body, status
end

local function downloadMain()
    local baseUrl = tostring(env.PSX_OG_MAIN_URL or DEFAULT_MAIN_URL)
    local lastError = nil
    local transport, transportCount = resolveRequestTransport()

    if not transport then
        error(
            "No safe executor HTTP transport found. The second game:HttpGet is disabled "
            .. "because it crashes this executor. Expected request/http_request/syn.request.",
            0
        )
    end

    state.Transport = transport.Label
    trace("03 main transport", transport.Label .. " | candidates=" .. tostring(transportCount))

    for attempt = 1, 3 do
        trace("04 downloading main", "attempt=" .. tostring(attempt))
        local success, response = pcall(function()
            return transport.Call({
                Url = baseUrl,
                Method = "GET",
                Headers = {
                    ["Cache-Control"] = "no-cache",
                    ["Pragma"] = "no-cache"
                }
            })
        end)
        local body, status = unpackResponse(response)

        if success
            and type(body) == "string"
            and #body >= 10000
            and (status == nil or (status >= 200 and status < 300))
            and not string.find(body, "<!DOCTYPE html", 1, true) then
            trace("05 main downloaded", "bytes=" .. tostring(#body))
            return body
        end

        lastError = success and string.format(
            "invalid response, status=%s bytes=%d",
            tostring(status),
            type(body) == "string" and #body or 0
        ) or tostring(response)
        if attempt < 3 then task.wait(0.4 * attempt) end
    end

    error("Main download failed after 3 attempts: " .. tostring(lastError), 0)
end

local function run()
    trace("00 loader entered", "version=" .. LOADER_VERSION)
    persist(ERROR_FILE, "")
    waitForGameReady()

    -- Keep the proven diagnostic behaviour, but make the pacing explicit so it
    -- also works on executors where writefile is missing or very fast.
    env.PSX_OG_TRACE_BOOT = true
    env.PSX_OG_SAFE_BOOT = true
    env.PSX_OG_SAFE_BOOT_DELAY = math.clamp(
        tonumber(env.PSX_OG_SAFE_BOOT_DELAY) or 0.03,
        0.01,
        0.25
    )

    local source = downloadMain()
    trace("06 compiling main")
    local chunk, compileError = loadstring(source)

    -- This separation is intentional. A direct loadstring(HttpGet()) call keeps
    -- the large source string alive on the same executor stack during startup.
    source = nil
    if not chunk then error("Main compile failed: " .. tostring(compileError), 0) end
    trace("07 main compiled")

    game:GetService("RunService").Heartbeat:Wait()
    task.wait(0.05)
    trace("08 executing main")
    local result = chunk()
    chunk = nil

    state.Running = false
    state.Ready = true
    state.FinishedAt = os.clock()
    trace("09 main ready", string.format("%.2fs", state.FinishedAt - state.StartedAt))
    return result
end

-- The loader itself is normally entered through loadstring(game:HttpGet(...))().
-- Do not start a second HttpGet while that outer request is still on the executor
-- stack: a few executors crash natively instead of raising a catchable Lua error.
state.Phase = "scheduled"
task.defer(function()
    task.wait(0.15)

    local success, result = xpcall(run, captureError)
    if not success then
        warn("[PSX LOADER] Startup failed:\n" .. tostring(result))
        return
    end

    state.Result = result
end)

return state
