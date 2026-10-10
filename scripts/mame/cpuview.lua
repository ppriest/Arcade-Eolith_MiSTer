-- Bytes as the main CPU reads them, for scripts/mame_cpuview.py: CV_RANGES "hexlo:hexlen,..." are
-- read through the program space one byte at a time (read_u8, the CPU's byte order) at frame 2, and
-- written in order to CV_OUT.
local mach = manager.machine
local sp = mach.devices[os.getenv("CORE_CPU") or ":maincpu"].spaces[os.getenv("CORE_SPACE") or "program"]
local n = 0
_G.__cv = emu.add_machine_frame_notifier(function()
    n = n + 1
    if n ~= 2 then return end
    local f = assert(io.open(os.getenv("CV_OUT"), "wb"))
    for spec in string.gmatch(os.getenv("CV_RANGES"), "([^,]+)") do
        local lo, len = spec:match("(%x+):(%x+)")
        lo, len = tonumber(lo, 16), tonumber(len, 16)
        local t = {}
        for a = lo, lo + len - 1 do t[#t + 1] = string.char(sp:read_u8(a)) end
        f:write(table.concat(t))
    end
    f:close()
    print("CPUVIEW_OK")
    mach:exit()
end)
