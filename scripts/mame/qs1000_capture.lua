-- Every write to the QS1000 wavetable registers (8052 xdata 0x200-0x211) with its 750 kHz tick, the format of
-- Arcade-Vamphalf_MiSTer scripts/mame/qs1000wave.lua, plus cheats: QC_POKES bytes written to the main CPU's
-- program space every frame (a MAME cheat's "run" script), so a capture can follow a PCB recording's play.
--   W <tick> <offset> <data>     L <tick> <data> (sound latch writes, QC_LATCH: hex address, QC_LATCH_SPACE)
-- QC_COIN: coin, then Start 30 frames later, every 300 frames from this frame (0: never). QC_FIRE: P1 button 1
-- tapped 4 frames down, 4 up, from this frame (0: never). QC_FRAMES: frames to run. Output QC_OUT.
local OUT    = assert(os.getenv("QC_OUT"))
local FRAMES = tonumber(os.getenv("QC_FRAMES") or "1800")
local COIN   = tonumber(os.getenv("QC_COIN") or "0")
local FIRE   = tonumber(os.getenv("QC_FIRE") or "0")
local LATCH  = os.getenv("QC_LATCH") or ""
local LSPACE = os.getenv("QC_LATCH_SPACE") or "io"
local POKES  = {}
for a, v in string.gmatch(os.getenv("QC_POKES") or "", "(%x+)=(%x+)") do
    POKES[#POKES + 1] = {tonumber(a, 16), tonumber(v, 16)}
end

local mach = manager.machine
local f = assert(io.open(OUT, "w"))
f:write("# QS1000 wave register writes: W <750 kHz tick> <offset> <data>\n")
local function now_ticks()
    local t = mach.time
    return t.seconds * 750000 + math.floor(t.attoseconds / 1333333333333)
end
QC_TAPS = {mach.devices[":qs1000:cpu"].spaces["xdata"]:install_write_tap(0x200, 0x211, "qc", function(o, d, m)
    if not mach:side_effects_disabled() then f:write(string.format("W %d %x %x\n", now_ticks(), o - 0x200, d & 0xff)) end
    return d
end)}
if LATCH ~= "" then
    local a = tonumber(LATCH, 16)
    QC_TAPS[2] = mach.devices[":maincpu"].spaces[LSPACE]:install_write_tap(a, a + 3, "qcl", function(o, d, m)
        if not mach:side_effects_disabled() then
            local v = d
            if m & 0xff == 0 then v = d >> 8 end
            if m & 0xffff == 0 then v = d >> 16 end
            if m & 0xffffff == 0 then v = d >> 24 end
            f:write(string.format("L %d %x\n", now_ticks(), v & 0xff))
        end
        return d
    end)
end
local prog = mach.devices[":maincpu"].spaces["program"]
local function press(field, on)
    for _, p in pairs(mach.ioport.ports) do
        local fld = p.fields[field]
        if fld then fld:set_value(on and 1 or 0) end
    end
end
local frame = 0
QC_FRAME = emu.add_machine_frame_notifier(function()
    frame = frame + 1
    for _, p in ipairs(POKES) do prog:write_u8(p[1], p[2]) end
    if COIN > 0 and frame >= COIN then
        local k = (frame - COIN) % 300
        press("Coin 1", k < 6)
        press("1 Player Start", k >= 30 and k < 36)
    end
    if FIRE > 0 then press("P1 Button 1", frame >= FIRE and (frame - FIRE) % 8 < 4) end
    if frame >= FRAMES then
        f:write(string.format("# end %d frames, tick %d\n", frame, now_ticks()))
        f:close()
        print("QC_OK")
        mach:exit()
    end
end)
