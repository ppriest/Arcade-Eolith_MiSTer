-- The sound board's inputs and outputs in order, for scripts/qs1000_wave_compare.py: the main CPU's
-- sound latch writes ("L <frame> <data> <seconds since power-on>", WV_LATCH hex) and the QS1000 8052's wavetable register writes
-- ("W <frame> <off> <data>", xdata 0x200-0x211) and its reads of the banked window ("R <frame> <addr> <data>"), the format of sim/sys_tb's +wave. COIN1 is pressed at
-- WV_COIN and START1 at WV_START, each for 6 frames (repeated every WV_COINREP / WV_STARTREP frames if set), as the bench's +coin/+start/+coinrep/+startrep; the run stops after
-- WV_FRAMES frames. Output WV_OUT.
local mach  = manager.machine
local OUT   = assert(os.getenv("WV_OUT"))
local LATCH = tonumber(os.getenv("WV_LATCH") or "fc600000", 16)
local COIN  = tonumber(os.getenv("WV_COIN") or "-1")
local START = tonumber(os.getenv("WV_START") or "-1")
local FRAMES = tonumber(os.getenv("WV_FRAMES") or "1200")
local CREP  = tonumber(os.getenv("WV_COINREP") or "0")    -- repeat every N frames (0: once)
local SREP  = tonumber(os.getenv("WV_STARTREP") or "0")
local function pressed(k, at, rep)
    if at < 0 or k < at then return false end
    if rep > 0 then return (k - at) % rep < 6 end
    return k < at + 6
end
local f = assert(io.open(OUT, "w"))
local n = 0
local qs = mach.devices[":qs1000:cpu"].spaces["xdata"]
-- the Gradation 2D's sound CPU, if the set has one: its data reads ("S <frame> <addr> <data>")
local sc = mach.devices[":soundcpu"]
if sc then
    _G.__wvs = (sc.spaces["xdata"] or sc.spaces["data"]):install_read_tap(0x0000, 0xffff, "wvs", function(o, d, m)
        if not mach:side_effects_disabled() then f:write(string.format("S %d %04x %02x\n", n + 1, o, d & 0xff)) end
        return d
    end)
end
_G.__wv = {
    mach.devices[":maincpu"].spaces["program"]:install_write_tap(LATCH, LATCH + 3, "wvl", function(o, d, m)
        f:write(string.format("L %d %02x %.9f\n", n + 1, d & 0xff, mach.time:as_double()))
        return d
    end),
    qs:install_read_tap(0x100, 0xffff, "wvr", function(o, d, m)
        if not mach:side_effects_disabled() then f:write(string.format("R %d %04x %02x\n", n + 1, o, d & 0xff)) end
        return d
    end),
    qs:install_write_tap(0x200, 0x211, "wvw", function(o, d, m)
        f:write(string.format("W %d %02x %02x\n", n + 1, o - 0x200, d & 0xff))
        return d
    end),
}
local function field(name)
    for _, p in pairs(mach.ioport.ports) do if p.fields[name] then return p.fields[name] end end
end
local fc, fs = field("Coin 1"), field("1 Player Start")
_G.__wvf = emu.add_machine_frame_notifier(function()
    n = n + 1
    local k = n + 1
    if fc then fc:set_value(pressed(k, COIN, CREP) and 1 or 0) end
    if fs then fs:set_value(pressed(k, START, SREP) and 1 or 0) end
    if n == FRAMES then
        f:close()
        print("WAVE_OK")
        mach:exit()
    end
end)
