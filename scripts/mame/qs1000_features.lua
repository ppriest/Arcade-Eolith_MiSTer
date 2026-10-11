-- The QS1000's register writes and the sample ROM entries each key-on uses, for scripts/qs1000_features.py,
-- which decodes the parts MAME's qs1000.cpp ignores. The 8052's writes to xdata 0x200-0x211:
--   W <frame> <off> <data>
-- and at each key-on (offset 0, data 0), the 6-byte note entry at the address registers (in the mode the
-- address was written: the script tracks MAME's global / channel split, [211] == 3 selecting the channel's
-- copy) and the 24-byte descriptor it points to:
--   K <frame> <ch> <table addr> <entry 6 bytes> <descriptor 24 bytes>
-- COIN1 at QF_COIN, START1 at QF_START, each for 6 frames and repeated every QF_REP frames (0: once); stops
-- after QF_FRAMES frames. Output QF_OUT.
local mach   = manager.machine
local OUT    = assert(os.getenv("QF_OUT"))
local FRAMES = tonumber(os.getenv("QF_FRAMES") or "3600")
local COIN   = tonumber(os.getenv("QF_COIN") or "600")
local START  = tonumber(os.getenv("QF_START") or "700")
local REP    = tonumber(os.getenv("QF_REP") or "0")
local f      = assert(io.open(OUT, "w"))
local rom    = mach.memory.regions[":qs1000"]
local size   = rom.size
local function rb(a) return rom:read_u8(a % size) end
local function hex(a, n)
    local t = {}
    for i = 0, n - 1 do t[#t + 1] = string.format("%02x", rb(a + i)) end
    return table.concat(t)
end
-- MAME's split (qs1000.cpp wave_w): offsets 1-0xd go to the selected channel's copy when [211] == 3,
-- else to the globals; key-on copies the globals' 0-0xf into the channel
local glob = {}
local chan = {}
for i = 0, 0x11 do glob[i] = 0 end
for c = 0, 31 do chan[c] = {} for i = 0, 15 do chan[c][i] = 0 end end
local n = 0
_G.__qf = mach.devices[":qs1000:cpu"].spaces["xdata"]:install_write_tap(0x200, 0x211, "qf", function(o, d, m)
    local off, v = o - 0x200, d & 0xff
    f:write(string.format("W %d %02x %02x\n", n + 1, off, v))
    local ch = glob[0xe] & 31
    if off == 0 then
        if v == 0 then
            for i = 0, 15 do chan[ch][i] = glob[i] end
            local r = chan[ch]
            local t = (r[1] << 16) | (r[2] << 8) | r[3]
            local base = (rb(t + 4) << 8) | rb(t + 5)
            f:write(string.format("K %d %d %06x %s %s\n", n + 1, ch, t, hex(t, 6), hex(base, 24)))
        end
    elseif off <= 0xd then
        if glob[0x11] == 3 then chan[ch][off] = v else glob[off] = v end
    else
        glob[off] = v
    end
    return d
end)
local function field(name)
    for _, p in pairs(mach.ioport.ports) do if p.fields[name] then return p.fields[name] end end
end
local fc, fs = field("Coin 1"), field("1 Player Start")
local function pressed(k, at)
    if at < 0 or k < at then return false end
    if REP > 0 then return (k - at) % REP < 6 end
    return k < at + 6
end
_G.__qff = emu.add_machine_frame_notifier(function()
    n = n + 1
    local k = n + 1
    if fc then fc:set_value(pressed(k, COIN) and 1 or 0) end
    if fs then fs:set_value(pressed(k, START) and 1 or 0) end
    if n == FRAMES then
        f:close()
        print("QF_OK")
        mach:exit()
    end
end)
