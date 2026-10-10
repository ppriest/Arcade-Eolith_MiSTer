-- MAME's frame-buffer flips per frame, the reference for rtl/debug/eo_perf.sv's flip gaps: a flip is a change of
-- the buffer bit in a write to FL_ADDR (FL_BIT; Vega 0xfca00000 bit 0, Gradation 2D 0xfc400000 bit 7, eolith16
-- 0xffe80000 bit 7). COIN1 pressed at FL_COIN and START1 at FL_START, 6 frames each. One line a frame to FL_OUT:
--   <frame> <flips in that frame>
local mach   = manager.machine
local OUT    = assert(os.getenv("FL_OUT"))
local ADDR   = tonumber(os.getenv("FL_ADDR"), 16)
local BIT    = tonumber(os.getenv("FL_BIT"))
local LEN    = tonumber(os.getenv("FL_LEN") or "4")   -- bytes the register spans (2 on eolith16's 16-bit bus)
local FRAMES = tonumber(os.getenv("FL_FRAMES") or "1200")
local COIN   = tonumber(os.getenv("FL_COIN") or "-1")
local START  = tonumber(os.getenv("FL_START") or "-1")
local f      = assert(io.open(OUT, "w"))
local sp     = mach.devices[":maincpu"].spaces["program"]
local n, flips, last = 0, 0, nil
_G.__fl = sp:install_write_tap(ADDR, ADDR + LEN - 1, "fl", function(o, d, m)
    local b = (d >> BIT) & 1
    if last ~= nil and b ~= last then flips = flips + 1 end
    last = b
    return d
end)
local function field(name)
    for _, p in pairs(mach.ioport.ports) do if p.fields[name] then return p.fields[name] end end
end
local fc, fs = field("Coin 1"), field("1 Player Start")
_G.__flf = emu.add_machine_frame_notifier(function()
    n = n + 1
    local k = n + 1
    if fc then fc:set_value((COIN >= 0 and k >= COIN and k < COIN + 6) and 1 or 0) end
    if fs then fs:set_value((START >= 0 and k >= START and k < START + 6) and 1 or 0) end
    f:write(string.format("%d %d\n", n, flips))
    flips = 0
    if n == FRAMES then
        f:close()
        print("FLIPS_OK")
        mach:exit()
    end
end)
