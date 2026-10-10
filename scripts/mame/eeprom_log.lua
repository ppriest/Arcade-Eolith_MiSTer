-- The Gradation 2D's 93C66 traffic (eolith.cpp systemcontrol_w 283-292, IN0 405-414): every system control
-- write (0xfc400000: CS bit 1, CLK bit 2, DI bit 3) and every IN0 read (0xfc000000: DO bit 3), with
-- MAME's time (the executing CPU's local time), from the EEPROM MAME's -nvram_directory gives. COIN1
-- pulsed at EE_COIN and every 97 frames after, START1 at EE_START and every 211. Ends at EE_FRAMES.
--   W <seconds> <data>    R <seconds> <data>
local mach   = manager.machine
local OUT    = assert(os.getenv("EE_OUT"))
local FRAMES = tonumber(os.getenv("EE_FRAMES") or "1200")
local COIN   = tonumber(os.getenv("EE_COIN") or "400")
local START  = tonumber(os.getenv("EE_START") or "500")
local f      = assert(io.open(OUT, "w"))
local sp     = mach.devices[":maincpu"].spaces["program"]
local function now() return mach.time:as_double() end
_G.__ee = {
    sp:install_write_tap(0xfc400000, 0xfc400003, "eew", function(o, d, m)
        f:write(string.format("W %.10f %08x\n", now(), d))
        return d
    end),
    sp:install_read_tap(0xfc000000, 0xfc000003, "eer", function(o, d, m)
        if not mach:side_effects_disabled() then f:write(string.format("R %.10f %08x\n", now(), d)) end
        return d
    end),
}
local function field(name)
    for _, p in pairs(mach.ioport.ports) do if p.fields[name] then return p.fields[name] end end
end
local fc, fs = field("Coin 1"), field("1 Player Start")
local n = 0
_G.__eef = emu.add_machine_frame_notifier(function()
    n = n + 1
    local k = n + 1
    if fc then fc:set_value((k >= COIN and (k - COIN) % 97 < 6) and 1 or 0) end
    if fs then fs:set_value((k >= START and (k - START) % 211 < 6) and 1 or 0) end
    if n == FRAMES then
        f:close()
        print("EEPROM_LOG_OK")
        mach:exit()
    end
end)
