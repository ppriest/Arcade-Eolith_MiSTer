-- The Gradation 2D sound CPU's data traffic (eolith.cpp sound_data_map 408-412): reads of the banked
-- sounddata window (0x0000-0x7fff, P1 bits 0-3 select a 32 KB page) and of the latch (0x8000), per
-- frame, with the most in one frame and the distinct 16-byte lines; and the main CPU's latch writes
-- (0xfc800000). COIN1 at SL_COIN, START1 at SL_START, each repeated (97 / 211 frames); P1 button 1
-- pulsed from START. One line to SL_OUT at frame SL_FRAMES.
local mach  = manager.machine
local OUT   = assert(os.getenv("SL_OUT"))
local FRAMES = tonumber(os.getenv("SL_FRAMES") or "1800")
local COIN  = tonumber(os.getenv("SL_COIN") or "400")
local START = tonumber(os.getenv("SL_START") or "500")
local snd   = mach.devices[":soundcpu"]
local ds    = snd.spaces["xdata"] or snd.spaces["data"]
local c = { win = 0, latch = 0, mainw = 0, per = 0, maxf = 0 }
local lines, frames_with = {}, 0
_G.__sl = {
    ds:install_read_tap(0x0000, 0x7fff, "slw", function(o, d, m)
        if not mach:side_effects_disabled() then c.win = c.win + 1; c.per = c.per + 1; lines[o >> 4] = true end
        return d
    end),
    ds:install_read_tap(0x8000, 0x8000, "sll", function(o, d, m)
        if not mach:side_effects_disabled() then c.latch = c.latch + 1 end
        return d
    end),
    mach.devices[":maincpu"].spaces["program"]:install_write_tap(0xfc800000, 0xfc800003, "slm", function(o, d, m)
        c.mainw = c.mainw + 1
        return d
    end),
}
local function field(name)
    for _, p in pairs(mach.ioport.ports) do if p.fields[name] then return p.fields[name] end end
end
local fc, fs, fb = field("Coin 1"), field("1 Player Start"), field("P1 Button 1")
local n = 0
_G.__slf = emu.add_machine_frame_notifier(function()
    n = n + 1
    local k = n + 1
    if fc then fc:set_value((k >= COIN and (k - COIN) % 97 < 6) and 1 or 0) end
    if fs then fs:set_value((k >= START and (k - START) % 211 < 6) and 1 or 0) end
    if fb then fb:set_value((k >= START and k % 20 < 4) and 1 or 0) end
    if c.per > c.maxf then c.maxf = c.per end
    if c.per > 0 then frames_with = frames_with + 1 end
    c.per = 0
    if n == FRAMES then
        local nl = 0
        for _ in pairs(lines) do nl = nl + 1 end
        local f = assert(io.open(OUT, "w"))
        f:write(string.format("%d frames: banked reads %d (max %d in a frame, in %d frames, %d distinct 16-byte lines); latch reads %d; main CPU latch writes %d\n",
            FRAMES, c.win, c.maxf, frames_with, nl, c.latch, c.mainw))
        f:close()
        print("SNDCPU_OK")
        mach:exit()
    end
end)
