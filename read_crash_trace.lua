local names = {
    "PSX_OG_loader_trace.txt",
    "PSX_OG_boot_trace.txt",
    "PSX_OG_loader_error.txt"
}

local report = {}
for _, name in ipairs(names) do
    local exists = true
    if type(isfile) == "function" then
        local ok, result = pcall(isfile, name)
        exists = ok and result == true
    end

    if exists and type(readfile) == "function" then
        local ok, contents = pcall(readfile, name)
        if ok then
            table.insert(report, "===== " .. name .. " =====\n" .. tostring(contents))
        end
    end
end

local text = #report > 0
    and table.concat(report, "\n\n")
    or "Diagnostic files were not found (or this executor has no readfile support)."

print(text)
if type(setclipboard) == "function" then
    pcall(setclipboard, text)
    print("[PSX TRACE] Report copied to clipboard.")
end

return text
