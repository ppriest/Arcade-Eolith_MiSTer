-- Bootstrap that makes Lua failures VISIBLE to the calling script.
--
-- MAME reports a broken autoboot script with a modal dialog. Headless, the
-- process sits on the dialog until something kills it and the capture
-- directory looks untouched. This wrapper writes the error to a file the
-- Python runner reads back:
--
--   syntax errors    loadfile() returns nil plus a message, BEFORE any of the
--                    target script runs. pcall cannot catch these, because
--                    there is nothing to call yet -- it has to be loadfile.
--   runtime errors   pcall around the script's top level only; an error inside
--                    a notifier or tap does not reach the loader.
--
-- Point -autoboot_script at THIS file and pass the real script in CORE_SCRIPT.

local OUT    = os.getenv("CORE_OUT")    or "."
local SCRIPT = os.getenv("CORE_SCRIPT")

local function record(kind, msg)
    local f = io.open(OUT .. "/lua_error.txt", "w")
    if f then
        f:write(kind .. ": " .. tostring(msg) .. "\n")
        f:close()
    end
    print("LUAFAIL " .. kind .. ": " .. tostring(msg))
end

if not SCRIPT then
    record("config", "CORE_SCRIPT is not set")
    manager.machine:exit()
    return
end

-- Syntax errors surface here, before anything is executed.
local chunk, lerr = loadfile(SCRIPT)
if not chunk then
    record("syntax", lerr)
    manager.machine:exit()
    return
end

-- Runtime errors during the script's own top level.
local ok, rerr = pcall(chunk)
if not ok then
    record("runtime", rerr)
    manager.machine:exit()
end
